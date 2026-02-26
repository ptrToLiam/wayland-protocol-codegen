pub fn main(init: std.process.Init) !void {
  const allocator = init.arena.allocator();
  var threaded: Io.Threaded = .init(allocator, .{ .environ = init.minimal.environ });
  defer threaded.deinit();
  const io = threaded.io();
  var args = try init.minimal.args.iterateAllocator(allocator);

  const program_name = args.next() orelse "wayland-protocol-codegen";
  const cwd = Io.Dir.cwd();

  var debug = false;
  var out_path_opt: ?[]const u8 = null;
  var first_protocol_file_opt: ?*EntryNode = null;
  var last_protocol_file_opt: ?*EntryNode = null;
  var protocol_count: u32 = 0;

  var arg_count: u16 = 0;
  while (args.next()) |arg| : (arg_count += 1) {
    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
      var backing: [1024]u8 = undefined;
      var stdout = Io.File.stdout().writer(io, &backing);
      try stdout.interface.print(UsageMsgFmt, .{program_name});
    } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
      out_path_opt = args.next();
    } else if (std.mem.eql(u8, arg, "--debug")) {
      debug = true;
    } else {
      const protocol_path = try allocator.create(EntryNode);
      protocol_path.* = .{
        .type = .file_name,
        .name = arg,
      };
      sll_push_end(
        protocol_path,
        &first_protocol_file_opt,
        &last_protocol_file_opt,
        &protocol_count,
      );
    }
  }

  if (arg_count == 0) {
    var backing: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &backing);
    try stdout.interface.print(UsageMsgFmt, .{program_name});
  }

  var cur_protocol_file_opt: ?*EntryNode = first_protocol_file_opt;
  var output: Output = .{};
  while (cur_protocol_file_opt) |cur_protocol_file| {
    cur_protocol_file_opt = cur_protocol_file.next;
    if (debug) std.debug.print(
      "reading protocol file :: {s}\n",
      .{ cur_protocol_file.name },
    );
    try generate_zig_code_tree(
      io,
      allocator,
      &output,
      cur_protocol_file.name,
    );
  }

  if (debug) std.debug.print("found {} protocols!\n", .{output.protocol_count});

  const out_file = if (out_path_opt) |out_path|
    try cwd.createFile(
      io,
      out_path,
      .{},
    )
  else return error.FileNotFound;
  var buf: [1024]u8 = undefined;
  var out = out_file.writerStreaming(io, &buf);
  const out_writer = &out.interface;

  try write_zig_code(
    out_writer,
    &output,
    debug,
  );

  try out.flush();
}

fn write_zig_code(
  writer: *Io.Writer,
  code_tree: *Output,
  debug: bool,
) !void {
  var protocol_opt: ?*EntryNode = code_tree.protocol_first;
  try writer.print(OutputBeginMsg, .{});
  _ = try writer.write(WaylandGeneralTypesCodePaste);
  while (protocol_opt) |protocol| : (protocol_opt = protocol.next) {
    if (debug) std.debug.print(
      "found {} interfaces in protocol {s}!\n",
      .{
        protocol.interface_count,
        protocol.name,
      },
    );

    try writer.print(
      ProtocolBeginFmt,
      .{ protocol.name },
    );

    var interface_opt: ?*EntryNode = protocol.interface_first;
    while (interface_opt) |interface| : (interface_opt = interface.next) {
      try write_wl_interface(
        writer,
        interface,
      );
    }

    try writer.print(
      ProtocolEndString,
      .{},
    );
  }

  // Write Combined Enum Union
  {
    _ = try writer.write(CombinedEnumBeginMsg);
    protocol_opt = code_tree.protocol_first;
    while (protocol_opt) |protocol| : (protocol_opt = protocol.next) {
      var interface_opt: ?*EntryNode = protocol.interface_first;
      while (interface_opt) |interface| : (interface_opt = interface.next) {
        var enum_opt: ?*EntryNode = interface.enum_first;
        while (enum_opt) |@"enum"| : (enum_opt = @"enum".next) {
          try writer.print(
            CombinedEnumEntryFmt,
            .{ interface.name, @"enum".name, interface.name, @"enum".identifier },
          );
        }
      }
    }
    _ = try writer.write(CombinedEnumEndMsg);
  }

  // Write Combined Event Union
  {
    _ = try writer.write(CombinedEventBeginMsg);
    protocol_opt = code_tree.protocol_first;
    while (protocol_opt) |protocol| : (protocol_opt = protocol.next) {
      var interface_opt: ?*EntryNode = protocol.interface_first;
      while (interface_opt) |interface| : (interface_opt = interface.next) {
        var event_opt: ?*EntryNode = interface.event_first;
        while (event_opt) |event| : (event_opt = event.next) {
          try writer.print(
            CombinedEventEntryFmt,
            .{interface.name, event.name, interface.name, event.identifier},
          );
        }
      }
    }
    _ = try writer.write(CombinedEventEndMsg);
  }

  // Write Combined Object Union
  {
    _ = try writer.write(CombinedInterfaceBeginMsg);
    protocol_opt = code_tree.protocol_first;
    while (protocol_opt) |protocol| : (protocol_opt = protocol.next) {
      var interface_opt: ?*EntryNode = protocol.interface_first;
      while (interface_opt) |interface| : (interface_opt = interface.next) {
        try writer.print(
          CombinedInterfaceEntryFmt,
          .{ interface.name, interface.identifier },
        );
      }
    }

    _ = try writer.write(
      \\
      \\  pub fn message_decode(o: Object, proxy: *Proxy, op: u16, data: []const u8) Event {
      \\    return switch (o) {
      \\
    );
    protocol_opt = code_tree.protocol_first;
    while (protocol_opt) |protocol| : (protocol_opt = protocol.next) {
      var interface_opt: ?*EntryNode = protocol.interface_first;
      while (interface_opt) |interface| : (interface_opt = interface.next) {
        if (interface.event_count > 0)
          try writer.print("      .{s} => |interface| @TypeOf(interface).message_decode(proxy, op, data),\n", .{ interface.name });
      }
    }
    _ = try writer.write(
      \\      else => .invalid,
      \\    };
      \\  }
      \\
    );
    _ = try writer.write(CombinedInterfaceEndMsg);
  }

  // add import std for scoped log
  _ = try writer.write(LogPaste);
}

fn write_wl_interface(
  writer: *Io.Writer,
  wl_interface: *EntryNode,
) !void {
  try writer.print(
    InterfaceBeginFmt,
    .{ wl_interface.name, wl_interface.name, wl_interface.name, wl_interface.name, wl_interface.name },
  );

  // write requests / events
  {
    try writer.print(
      InterfaceBeginSectionFmt,
      .{ wl_interface.name, "MESSAGES" },
    );

    var message_opt: ?*EntryNode = wl_interface.request_first;
    while (message_opt) |wl_request| : (message_opt = wl_request.next) {
      try write_wl_message(writer, wl_interface, wl_request);
    }


    if (wl_interface.event_count > 0) {

      message_opt = wl_interface.event_first;
      while (message_opt) |wl_event| : (message_opt = wl_event.next) {
        try write_wl_message(writer, wl_interface, wl_event);
      }

      // write event parse
      _ = try writer.write(MessageDecodeBeginMsg);
      message_opt = wl_interface.event_first;
      var opcode: u16 = 0;
      while (message_opt) |wl_event| : (message_opt = wl_event.next) {
        defer opcode += 1;
        try writer.print("        {d} => {{\n", .{opcode});
        try write_wl_message_decode(writer, wl_interface.name, wl_event);
        try writer.print("        }},\n", .{});
      }
      _ = try writer.write(MessageDecodeEndMsg);
    }

    try writer.print(
      InterfaceEndSectionFmt,
      .{},
    );
  }

  // write enums / bitfields
  if (wl_interface.enum_count > 0) {
    try writer.print(
      InterfaceBeginSectionFmt,
      .{ wl_interface.name, "ENUMS" },
    );

    var enum_opt: ?*EntryNode = wl_interface.enum_first;
    while (enum_opt) |wl_enum| : (enum_opt = wl_enum.next) {
      try write_wl_enum(writer, wl_enum);
    }

    try writer.print(
      InterfaceEndSectionFmt,
      .{},
    );
  }

  try writer.print(
    InterfaceEndFmt,
    .{ wl_interface.name, wl_interface.version.? },
  );
}

fn write_wl_message(
  writer: *Io.Writer,
  wl_interface: *EntryNode,
  wl_message: *EntryNode,
) !void {
  switch (wl_message.type) {
    .request => {
      try writer.print(
        ClientRequestBeginFmt,
        .{ wl_message.identifier, wl_interface.identifier },
      );
      if (wl_message.arg_count > 0) {
        try write_wl_args(
          writer,
          wl_message,
        );
      }
      try writer.print(
        ClientRequestArgsEndFmt,
        .{ wl_message.arg_type.?, wl_message.opcode },
      );

      // request body
      {
        if (!std.mem.eql(u8, wl_message.arg_type.?, "void")) {
          try writer.print(
            ClientRequestObjectCreateFmt,
            .{ wl_message.arg_type.? },
          );
          if (std.mem.eql(u8, wl_message.arg_type.?, "InterfaceT")) {
            _ = try writer.write(ClientRequestInterfaceBindVersionWarn);
          }
          try write_wl_message_encode(
            writer,
            wl_message,
          );
          try writer.print(
            ClientRequestObjectStoreFmt,
            .{ }
          );
        } else {
          try write_wl_message_encode(
            writer,
            wl_message,
          );
        }
      }

      try writer.print(
        ClientRequestEndFmt,
        .{},
      );
    },
    .event => {
      if (wl_message.arg_count > 0) {
        try writer.print(
          ClientEventBeginFmt,
          .{wl_message.identifier},
        );
        try write_wl_args(
          writer,
          wl_message,
        );
        try writer.print(
          ClientEventEndFmt,
          .{},
        );
      } else {
        try writer.print(
          ClientEventBeginEmptyFmt,
          .{wl_message.identifier},
        );
      }
    },
    else => return error.NotAWlMessage,
  }
}

fn write_wl_enum(
  writer: *Io.Writer,
  wl_enum: *EntryNode,
) !void {
  if (wl_enum.type == .bitfield)
    try writer.print(BitfieldBeginFmt, .{wl_enum.identifier})
  else if (wl_enum.type == .@"enum")
    try writer.print(EnumBeginFmt, .{wl_enum.identifier})
  else
    return error.NotAWlEnum;

  try write_wl_args(writer, wl_enum);

  if (wl_enum.type == .bitfield)
    try writer.print(
      BitfieldEndFmt,
      .{ 32 - wl_enum.arg_count },
    )
  else if (wl_enum.type == .@"enum")
    try writer.print(
      EnumEndFmt,
      .{ wl_enum.identifier, wl_enum.identifier },
    );
}

fn write_wl_args(
  writer: *Io.Writer,
  wl_interface_entry: *EntryNode,
) !void {
  switch (wl_interface_entry.type) {
    .bitfield => {
      var bitfield_entry_opt: ?*EntryNode = wl_interface_entry.arg_first;
      while (bitfield_entry_opt) |entry| : (bitfield_entry_opt = entry.next) {
        try writer.print(BitfieldEntryFmt, .{entry.identifier});
      }
    },
    .@"enum" => {
      var enum_entry_opt: ?*EntryNode = wl_interface_entry.arg_first;
      while (enum_entry_opt) |entry| : (enum_entry_opt = entry.next) {
        if (entry.value) |entry_value| {
          try writer.print(EnumEntryValueFmt, .{entry.identifier, entry_value});
        } else {
          try writer.print(EnumEntryNoValueFmt, .{entry.identifier});
        }
      }
    },
    .event => {
      var event_arg_opt: ?*EntryNode = wl_interface_entry.arg_first;
      while (event_arg_opt) |event_arg| : (event_arg_opt = event_arg.next) {
        try writer.print(
          ClientEventEntryFmt,
          .{ event_arg.identifier, event_arg.arg_type.? },
        );
      }
    },
    .request => {
      var request_arg_opt: ?*EntryNode = wl_interface_entry.arg_first;
      while (request_arg_opt) |request_arg| : (request_arg_opt = request_arg.next) {
        if (request_arg.data_type == .new_id and request_arg.interface == null) {
          try writer.print(
            ClientEventEntryFmt,
            .{ "InterfaceT", "type" },
          );
          try writer.print(
            ClientEventEntryFmt,
            .{ "version", "u32" },
          );
        } else if (request_arg.data_type != .new_id) {
          try writer.print(
            ClientEventEntryFmt,
            .{ request_arg.identifier, request_arg.arg_type.? },
          );
        }
      }
    },
    .invalid, .file_name, .protocol, .interface, .arg => return error.InvalidNodeType,
  }
}

fn write_wl_message_encode(
  writer: *Io.Writer,
  wl_message: *EntryNode,
) !void {
  _ = try writer.write(
    MessageEncodeBeginMsg,
  );
  const is_bind_fn = std.mem.eql(u8, "InterfaceT", wl_message.arg_type.?);
  var arg_opt: ?*EntryNode = wl_message.arg_first;
  while (arg_opt) |arg| : (arg_opt = arg.next) {
    switch (arg.data_type) {
      .uint => {
        if (arg.type == .@"enum") {
          try writer.print(
            \\        .{{ .@"enum" = .{{ .{s} = {s} }} }},
            \\
            , .{ arg.arg_type.?, arg.identifier }
          );
        } else if (!std.mem.eql(u8, arg.arg_type.?, "u32")) {
          try writer.print(
            "        .{{ .uint = {s}.toInt() }},\n",
            .{ arg.identifier }
          );
        } else {
          try writer.print(
            "        .{{ .uint = {s} }},\n",
            .{ arg.identifier }
          );
        }
      },
      .string => {
        try writer.print(
          \\        .{{ .string = {s} }},
          \\
          , .{ arg.identifier }
        );
      },
      .object => {
        try writer.print(
          \\        .{{ .object = {s}.toInt() }},
          \\
          , .{ arg.identifier }
        );
      },
      .array => {
        try writer.print(
          \\        .{{ .array = {s} }},
          \\
          , .{ arg.identifier }
        );
      },
      .int => {
        try writer.print(
          \\        .{{ .int = {s} }},
          \\
          , .{ arg.identifier }
        );
      },
      .new_id => {
        if (!is_bind_fn) {
          try writer.print(
            \\        .{{ .new_id = result.toInt() }},
            \\
            , .{ }
          );
        } else {
          try writer.print(
            \\        .{{ .string = InterfaceT.Name }},
            \\        .{{ .uint = selected_version }},
            \\        .{{ .new_id = result.toInt() }},
            \\
            , .{ }
          );
        }
      },
      .fd => {
        try writer.print(
          \\        .{{ .fd = {s} }},
          \\
          , .{ arg.identifier }
        );
      },
      .fixed => {
        try writer.print(
          \\        .{{ .fixed = {s} }},
          \\
          , .{ arg.identifier }
        );
      },
      .invalid, .destructor => {},
    }
  }
  _ = try writer.write(MessageEncodeEndMsg);
}

fn write_wl_message_decode(
  writer: *Io.Writer,
  wl_interface_name: []const u8,
  wl_message: *EntryNode,
) !void {
  var arg_opt: ?*EntryNode = wl_message.arg_first;
  _ = try writer.write(MessageDecodeArgsBeginMsg);
  while (arg_opt) |arg| : (arg_opt = arg.next) {
    const arg_undef = switch (arg.type) {
      else => "undefined",
    };
    _ = try writer.print(MessageDecodeArgsEntryFmt, .{ @tagName(arg.data_type), arg_undef });
  }
  _ = try writer.write(MessageDecodeArgsEndMsg);
  _ = try writer.write("          proxy.message_decode(&args_in, data);\n");

  _ = try writer.print(
    "          break :event .{{\n            .{s}_{s} = ",
    .{ wl_interface_name, wl_message.name },
  );
  if (wl_message.arg_count == 0) {
    _ = try writer.print("{{}},\n", .{});
  } else {
    _ = try writer.print(".{{\n", .{});
    arg_opt = wl_message.arg_first;
    var arg_no: u16 = 0;
    while (arg_opt) |arg| : (arg_opt = arg.next) {
      defer arg_no += 1;
      if (arg.data_type == .uint and !std.mem.eql(u8, arg.arg_type.?, "u32")) {
        _ = try writer.print("              .{s} = .fromInt(args_in[{d}].{s}),\n", .{ arg.name, arg_no, @tagName(arg.data_type) });
      } else if (arg.data_type == .object and arg.interface != null) {
        _ = try writer.print("              .{s} = .fromInt(args_in[{d}].{s}),\n", .{ arg.name, arg_no, @tagName(arg.data_type) });
      } else {
        _ = try writer.print("              .{s} = args_in[{d}].{s},\n", .{ arg.name, arg_no, @tagName(arg.data_type) });
      }
    }
    _ = try writer.print("            }},\n", .{});
  }
  _ = try writer.print("          }};\n", .{});
}

const MessageDecodeBeginMsg =
\\
\\  pub fn message_decode(
\\    proxy: *Proxy,
\\    opcode: u16,
\\    data: []const u8
\\  ) Event {
\\    return event: {
\\      switch (opcode) {
\\
;
const MessageDecodeArgsBeginMsg =
\\          var args_in = [_]MessageArg{
\\
;
const MessageDecodeArgsEntryFmt =
\\            .{{ .{s} = {s} }},
\\
;
const MessageDecodeArgsEndMsg =
\\          };
\\
;
const MessageDecodeEndMsg =
\\        else => @panic("Invalid Opcode"),
\\      }
\\    };
\\  }
\\
;

fn generate_zig_code_tree(
  io: Io,
  arena: std.mem.Allocator,
  output: *Output,
  spec_filename: []const u8,
) !void {
  var local_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
  defer local_arena.deinit();
  const local_allocator = local_arena.allocator();

  const xml_spec_data = try Io.Dir.cwd().readFileAlloc(
    io,
    spec_filename,
    arena,
    .unlimited
  );
  const spec = try Xml.parse(local_allocator, xml_spec_data);

  const protocol = try arena.create(EntryNode);
  try fetch_entry_data(arena, protocol, spec.root, .protocol);

  defer sll_push_end(
    protocol,
    &output.protocol_first,
    &output.protocol_last,
    &output.protocol_count,
  );

  var spec_interfaces = spec.root.findChildrenByTag("interface");
  while (spec_interfaces.next()) |spec_interface| {
    const interface = try arena.create(EntryNode);
    try fetch_entry_data(arena, interface, spec_interface, .interface);
    defer sll_push_end(
      interface,
      &protocol.interface_first,
      &protocol.interface_last,
      &protocol.interface_count,
    );

    var spec_interface_enums = spec_interface.findChildrenByTag("enum");
    while (spec_interface_enums.next()) |spec_interface_enum| {
      const @"enum" = try arena.create(EntryNode);
      try fetch_entry_data(arena, @"enum", spec_interface_enum, .@"enum");
      defer sll_push_end(
        @"enum",
        &interface.enum_first,
        &interface.enum_last,
        &interface.enum_count,
      );

      var enum_entries = spec_interface_enum.findChildrenByTag("entry");
      while (enum_entries.next()) |enum_entry| {
        const entry = try arena.create(EntryNode);
        try fetch_entry_data(arena, entry, enum_entry, .@"arg");
        defer sll_push_end(
          entry,
          &@"enum".arg_first,
          &@"enum".arg_last,
          &@"enum".arg_count,
        );
      }
    }

    var spec_interface_events = spec_interface.findChildrenByTag("event");
    while (spec_interface_events.next()) |spec_interface_event| {
      const event = try arena.create(EntryNode);
      try fetch_entry_data(arena, event, spec_interface_event, .event);
      defer sll_push_end(
        event,
        &interface.event_first,
        &interface.event_last,
        &interface.event_count,
      );

      var event_entries = spec_interface_event.findChildrenByTag("arg");
      while (event_entries.next()) |event_entry| {
        const entry = try arena.create(EntryNode);
        try fetch_entry_data(arena, entry, event_entry, .@"arg");
        defer sll_push_end(
          entry,
          &event.arg_first,
          &event.arg_last,
          &event.arg_count,
        );
      }
    }

    var request_opcode: u16 = 0;
    var spec_interface_requests = spec_interface.findChildrenByTag("request");
    while (spec_interface_requests.next()) |spec_interface_request| : (request_opcode += 1) {
      const request = try arena.create(EntryNode);
      try fetch_entry_data(arena, request, spec_interface_request, .request);
      request.opcode = request_opcode;
      request.arg_type = "void";
      defer sll_push_end(
        request,
        &interface.request_first,
        &interface.request_last,
        &interface.request_count,
      );

      var request_args = spec_interface_request.findChildrenByTag("arg");
      while (request_args.next()) |request_arg| {
        const arg = try arena.create(EntryNode);
        try fetch_entry_data(arena, arg, request_arg, .@"arg");
        if (arg.data_type == .new_id) {
          if (arg.interface == null) {
            request.arg_type = "InterfaceT";
          } else {
            request.arg_type = arg.interface;
          }
        }
        sll_push_end(
          arg,
          &request.arg_first,
          &request.arg_last,
          &request.arg_count,
        );
      }
    }
  }
}

fn fetch_entry_data(
  arena: std.mem.Allocator,
  entry: *EntryNode,
  element: *const Xml.Element,
  @"type": EntryType,
) !void {
  const entry_name = try arena.dupe(u8, element.getAttribute("name").?);
  const entry_version = if (element.getAttribute("version")) |ver|
    try arena.dupe(u8, ver)
  else null;
  const entry_summary = if (element.getAttribute("summary")) |sum|
    try arena.dupe(u8, sum)
  else null;
  const entry_description = if (element.getCharData("description")) |desc|
    try arena.dupe(u8, desc)
  else null;
  const entry_value = if (element.getAttribute("value")) |val|
    try arena.dupe(u8, val)
  else null;
  const entry_interface = if (element.getAttribute("interface")) |int|
    try arena.dupe(u8, int)
  else null;
  const entry_nullable = (element.getAttribute("nullable") != null);
  const entry_type =
    if (@"type" == .@"enum" and
    element.getAttribute("bitfield") != null)
      .bitfield
    else
      @"type";

  const entry_identifier = try toIdentifier(
    arena,
    entry_name,
    entry_type,
  );

  const entry_arg_type, const entry_data_type = arg_type: {
    if (element.getAttribute("type")) |typ| {
      const enum_t = element.getAttribute("enum");
      const bitfield = if (enum_t) |_|
        if (element.getAttribute("bitfield")) |_|
          true
        else
          false
        else false;

      _ = bitfield;

      const data_type = std.meta.stringToEnum(DataType, typ).?;
      break :arg_type
      .{
        if (data_type == .object and entry_interface != null)
          entry_interface
        else if (data_type == .uint and enum_t != null)
          try toIdentifier(arena, enum_t.?, .@"enum")
        else
          data_type.zigTypeString(),
        data_type,
      };
    }

    break :arg_type .{ null, .invalid };
  };

  entry.* = .{
    .description = entry_description,
    .version = entry_version,
    .summary = entry_summary,
    .nullable = entry_nullable,
    .value = entry_value,
    .arg_type = entry_arg_type,
    .interface = entry_interface,
    .name = entry_name,
    .identifier = entry_identifier,
    .data_type = entry_data_type,
    .type = entry_type,
  };
}

const WaylandGeneralTypesCodePaste =
\\
\\pub const MessageArg = union(enum) {
\\  string: [:0]const u8,
\\  array: []const u8,
\\  @"enum": Enum,
\\  new_id: u32,
\\  object: u32,
\\  fixed: f32,
\\  uint: u32,
\\  int: i32,
\\  fd: i32,
\\};
\\
\\pub const Proxy = struct {
\\  ctx: *anyopaque,
\\  vtable: VTable,
\\
\\  pub fn message_decode(
\\    noalias proxy: *Proxy,
\\    noalias args_out: []MessageArg,
\\    noalias message: []const u8,
\\  ) void {
\\    @call(
\\      .auto,
\\      proxy.vtable.message_decode,
\\      .{ proxy.ctx, args_out, message },
\\    );
\\  }
\\
\\  pub fn message_encode(
\\    noalias proxy: *Proxy,
\\    id: u32,
\\    opcode: u16,
\\    noalias args: []const ?MessageArg,
\\  ) void {
\\    @call(
\\      .auto,
\\      proxy.vtable.message_encode,
\\      .{ proxy.ctx, id, opcode, args },
\\    );
\\  }
\\
\\  pub fn get_id(
\\    proxy: *Proxy,
\\  ) u32 {
\\    return @call(
\\      .auto,
\\      proxy.vtable.get_id,
\\      .{ proxy.ctx },
\\    );
\\  }
\\
\\  pub fn put_object(
\\    proxy: *Proxy,
\\    object: Object,
\\  ) void {
\\    @call(
\\      .auto,
\\      proxy.vtable.put_object,
\\      .{ proxy.ctx, object },
\\    );
\\  }
\\
\\  pub fn destroy_object(
\\    proxy: *Proxy,
\\    object_id: u32,
\\  ) void {
\\    @call(
\\      .auto,
\\      proxy.vtable.destroy_object,
\\      .{ proxy.ctx, object_id },
\\    );
\\  }
\\
\\  const VTable = struct {
\\    message_decode: MessageDecodeFn,
\\    message_encode: MessageEncodeFn,
\\    get_id: GetIdFn,
\\    put_object: PutObjectFn,
\\    destroy_object: DestroyObjectFn,
\\  };
\\};
\\
\\pub const MessageDecodeFn = *const fn (
\\  noalias ctx: *anyopaque,
\\  args_out: []MessageArg,
\\  noalias message: []const u8
\\) void;
\\
\\pub const MessageEncodeFn = *const fn (
\\  noalias ctx: *anyopaque,
\\  id: u32,
\\  opcode: u16,
\\  noalias args: []const ?MessageArg,
\\) void;
\\
\\pub const GetIdFn = *const fn (
\\  noalias ctx: *anyopaque,
\\) u32;
\\
\\pub const PutObjectFn = *const fn (
\\  noalias ctx: *anyopaque,
\\  object: Object,
\\) void;
\\
\\pub const DestroyObjectFn = *const fn (
\\  noalias ctx: *anyopaque,
\\  object_id: u32,
\\) void;
\\
\\pub fn BitfieldMixin(comptime T: type) type {
\\  const int_type = @typeInfo(T).@"struct".backing_integer.?;
\\
\\  return struct {
\\    pub fn toInt(self: T) Int {
\\      return @bitCast(self);
\\    }
\\    pub fn fromInt(int: Int) T {
\\      return @bitCast(int);
\\    }
\\    pub fn not(self: T) T {
\\      return fromInt(~toInt(self));
\\    }
\\
\\    pub fn either(a: T, b: T) T {
\\      return fromInt(toInt(a) | toInt(b));
\\    }
\\    pub fn both(a: T, b: T) T {
\\      return fromInt(toInt(a) & toInt(b));
\\    }
\\    pub fn eql(a: T, b: T) bool {
\\      return fromInt(a) == fromInt(b);
\\    }
\\    pub fn contains(a: T, b: T) bool {
\\      return toInt(both(a, b)) == toInt(b);
\\    }
\\    pub const Int = int_type;
\\  };
\\}
\\
\\
;

const UsageMsgFmt =
\\Generate code for interacting with a set of specified Wayland protocols in
\\a less callback-heavy manner.
\\
\\The core Wayland specification document can be obtained from
\\https://gitlab.freedesktop.org/wayland/wayland
\\and other protocols can be found at
\\https://gitlab.freedesktop.org/wayland/wayland-protocols
\\
\\Usage: {s} [options] <xml specification paths> -o <output zig source>
\\Options:
\\  -h --help       Show this message and exit.
\\  --debug         Write unformatted source to STDOUT in error cases.
\\  -o --out <name> Output file to write to
\\
;

const OutputBeginMsg =
\\//  This file is generated from provided Wayland XML specifications by
\\//  wayland-protocol-codegen and should NOT be edited manually.
\\
;

const ProtocolBeginFmt =
\\//-----------------------------------------------------------------------------
\\// BEGIN Protocol {s}
\\//-----------------------------------------------------------------------------
\\
;

const ProtocolEndString =
\\
\\//-----------------------------------------------------------------------------
\\
\\
;

const InterfaceBeginFmt =
\\
\\pub const {s} = enum (u32) {{
\\  _,
\\
\\  pub fn object(self: {s}) Object {{
\\    return .{{ .{s} = self }};
\\  }}
\\
\\  pub fn toInt(self: {s}) u32 {{
\\    return @intFromEnum(self);
\\  }}
\\
\\  pub fn fromInt(int: u32) {s} {{
\\    return @enumFromInt(int);
\\  }}
\\
;
const InterfaceBeginSectionFmt =
\\
\\  //---------------------------------------------------------------------------
\\  // BEGIN {s} {s}
\\  //---------------------------------------------------------------------------
\\
;
const InterfaceEndSectionFmt =
\\  //---------------------------------------------------------------------------
\\
;
const InterfaceEndFmt =
\\
\\  pub const Name = "{s}";
\\  pub const Version = {s};
\\}};
\\
;

const ClientRequestBeginFmt =
\\
\\  pub fn {s}(
\\    noalias self: *const {s},
\\    noalias proxy: *Proxy,
\\
;
const ClientRequestArgEntryFmt =
\\    {s}: {s},
\\
;
const ClientRequestArgsEndFmt =
\\  ) {s} {{
\\    const Opcode = {};
\\
;

const ClientRequestObjectCreateFmt =
\\    const result: {s} = .fromInt(proxy.get_id());
\\
;
const ClientRequestInterfaceBindVersionWarn =
\\
\\    if (InterfaceT.Version != version) {
\\      log.warn(
\\        "Interface {s} version mismatch :: Client expects v{} — Compositor has v{}",
\\        .{
\\          InterfaceT.Name,
\\          InterfaceT.Version,
\\          version,
\\        },
\\      );
\\    }
\\    const selected_version = @min(InterfaceT.Version, version);
\\
;
const ClientRequestObjectStoreFmt =
\\
\\    proxy.put_object(result.object());
\\    return result;
\\
;
const ClientRequestEndFmt =
\\  }}
\\
;

const ClientEventBeginFmt =
\\
\\  pub const {s} = struct {{
\\
;
const ClientEventBeginEmptyFmt =
\\
\\  pub const {s} = void;
\\
;
const ClientEventEntryFmt =
\\    {s}: {s},
\\
;
const ClientEventEndFmt =
\\  }};
\\
;

const BitfieldBeginFmt =
\\
\\  pub const {s} = packed struct (u32) {{
\\
;

const BitfieldEntryFmt =
\\    {s}: bool = false,
\\
;
const BitfieldEndFmt =
\\
\\    __reserved_bits: u{} = 0,
\\
\\    pub const toInt = Mixin.toInt;
\\    pub const fromInt = Mixin.fromInt;
\\    pub const not = Mixin.not;
\\    pub const either = Mixin.either;
\\    pub const both = Mixin.both;
\\    pub const eql = Mixin.eql;
\\    pub const contains = Mixin.contains;
\\
\\    const Mixin = BitfieldMixin(@This());
\\  }};
\\
;

const EnumBeginFmt =
\\
\\  pub const {s} = enum (u32) {{
\\
;
const EnumEntryValueFmt =
\\    {s} = {s},
\\
;
const EnumEntryNoValueFmt =
\\    {s},
\\
;
const EnumEndFmt =
\\
\\    pub fn toInt(self: {s}) u32 {{
\\      return @intFromEnum(self);
\\    }}
\\    pub fn fromInt(int: u32) {s} {{
\\      return @enumFromInt(int);
\\    }}
\\  }};
\\
;

const MessageEncodeBeginMsg =
\\    proxy.message_encode(
\\      self.toInt(),
\\      Opcode,
\\      &.{
\\
;
const MessageEncodeEndMsg =
\\      },
\\    );
\\
;

const CombinedInterfaceBeginMsg =
\\pub const Object = union (enum) {
\\
;
const CombinedInterfaceEntryFmt =
\\  {s}: {s},
\\
;
const CombinedInterfaceEndMsg =
\\};
\\
;

const CombinedEventBeginMsg =
\\pub const Event = union (enum) {
\\  invalid: void,
\\
;
const CombinedEventEntryFmt =
\\  {s}_{s}: {s}.{s},
\\
;
const CombinedEventEndMsg =
\\};
\\
;

const CombinedEnumBeginMsg =
\\pub const Enum = union (enum) {
\\  invalid: void,
\\
;
const CombinedEnumEntryFmt =
\\  {s}_{s}: {s}.{s},
\\
;
const CombinedEnumEndMsg =
\\};
\\
;

const LogPaste =
\\const log = @import("std").log.scoped(.WaylandProtocols);
\\
;

const DataType = enum (u32) {
  invalid,
  // u32
  uint, // uint may also be an enum/bitfield type
  object,
  new_id,
  // i32
  int,
  // c_int -- but sent/received in ancillary data
  fd,
  // fixed point float -> f32
  fixed,
  // []u8
  array,
  // [:0]u8
  string,

  // basically exclusive to .destroy() requests
  destructor,

  pub fn zigType(comptime data_type: DataType) type {
    return switch (data_type) {
      .destructor, .invalid => void,
      .uint, .object, .new_id => u32,
      .int => i32,
      .fd => c_int,
      .fixed => f32,
      .array => []const u8,
      .string => [:0]const u8,
    };
  }
  pub fn zigTypeString(data_type: DataType) []const u8 {
    return switch (data_type) {
      .destructor, .invalid => @typeName(void),
      .uint, .object, .new_id => @typeName(u32),
      .int => @typeName(i32),
      .fd => @typeName(c_int),
      .fixed => @typeName(f32),
      .array => @typeName([]const u8),
      .string => @typeName([:0]const u8),
    };
  }
};

const EntryType = enum (u32) {
  invalid,
  file_name,
  protocol,
  interface,
  request,
  event,
  @"enum",
  bitfield,
  arg,
};

const EntryNode = struct {
  next: ?*EntryNode = null,
  interface_first: ?*EntryNode = null,
  interface_last: ?*EntryNode = null,
  interface_count: u32 = 0,
  enum_first: ?*EntryNode = null,
  enum_last: ?*EntryNode = null,
  enum_count: u32 = 0,
  event_first: ?*EntryNode = null,
  event_last: ?*EntryNode = null,
  event_count: u32 = 0,
  request_first: ?*EntryNode = null,
  request_last: ?*EntryNode = null,
  request_count: u32 = 0,
  arg_first: ?*EntryNode = null,
  arg_last: ?*EntryNode = null,
  arg_count: u32 = 0,
  description: ?[]const u8 = null,
  summary: ?[]const u8 = null,
  interface: ?[]const u8 = null,
  version: ?[]const u8 = null,
  value: ?[]const u8 = null,
  arg_type: ?[]const u8 = null,
  name: []const u8,
  opcode: u16 = 0,
  identifier: []const u8 = undefined,
  type: EntryType = .invalid,
  data_type: DataType = .invalid,
  nullable: bool = false,
};

const Output = struct {
  protocol_first: ?*EntryNode = null,
  protocol_last: ?*EntryNode = null,
  protocol_count: u32 = 0,
};

fn sll_push_front(node: *EntryNode, first: *?*EntryNode, last: *?*EntryNode, count: *u32) void {
  if (first.*) |first_old| {
    first.* = node;
    node.next = first_old;
  } else {
    first.* = node;
    last.* = node;
  }
  count.* += 1;
}

fn sll_push_end(node: *EntryNode, first: *?*EntryNode, last: *?*EntryNode, count: *u32) void {
  if (last.*) |last_old| {
    last_old.next = node;
    last.* = node;
  } else {
    first.* = node;
    last.* = node;
  }
  count.* += 1;
  }

fn sll_remove(node: *EntryNode, first: *?*EntryNode, last: *?*EntryNode, count: *u32) void {
  if (first.* == null and last.* == null) return;

  if (first.* != null and first.*.? == node) {
    first.* = node.next;
    node.next = null;
    count.* -= 1;
    if (count.* == 0) last.* = null;
  } else {
    var iter: ?*EntryNode = first.*;
    while (iter) |cur| : (iter = cur.next) {
      if (cur.next) |next| if (next == node) {
        cur.next = node.next;
        if (last.*.? == node) last.* = cur;
        node.next = null;
        count.* -= 1;
      };
    }
  }
}

fn is_digit(char: u8) bool {
  return (char >= '0' and char <= '9');
}

pub fn toIdentifier(
  allocator: std.mem.Allocator,
  string: []const u8,
  entry_type: EntryType,
) ![]const u8 {
  std.debug.assert(string.len > 0);

  if (entry_type == .@"enum" or entry_type == .bitfield) {
    const name = try snake_to_pascal(allocator, string);
    return name;
  }

  if (is_digit(string[0]) or Keywords.has(string)) {
    return try std.fmt.allocPrint(allocator, "@\"{s}\"", .{ string });
  }

  return string;
}

fn snake_to_pascal(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {

  const underscore_count, const namespace_end = uc_ne: {
    var n_end: usize = 0;
    var count: u32 = 0;
    for (str, 0..) |char, idx| {
      if (char == '_') count += 1;
      if (n_end == 0 and char == '.') { n_end = idx; count = 0; }
    }
    break :uc_ne .{ count, if (n_end > 0) n_end else null  };
  };

  var out_str = try allocator.alloc(u8, str.len - underscore_count);
  var next_is_upper = true;
  var out_idx: u32 = 0;

  for (str) |char| {
    if (namespace_end) |ne| {
      if (out_idx > ne) {
        if (char == '_') {
          next_is_upper = true;
        } else {
          defer out_idx += 1;
          if (next_is_upper) {
            next_is_upper = false;
            out_str[out_idx] = std.ascii.toUpper(char);
          } else out_str[out_idx] = char;
        }
      } else {
        defer out_idx += 1;
        out_str[out_idx] = char;
      }
    } else {
      if (char == '_') {
        next_is_upper = true;
      } else {
        defer out_idx += 1;
        if (next_is_upper) {
          next_is_upper = false;
          out_str[out_idx] = std.ascii.toUpper(char);
        } else out_str[out_idx] = char;
      }
    }
  }

  return out_str;
}

const Io = std.Io;
const Keywords = std.zig.Token.keywords;

const Xml = @import("xml.zig");
const std = @import("std");
