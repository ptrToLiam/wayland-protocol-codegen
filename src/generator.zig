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
  var lang_str_opt: ?[]const u8 = null;
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
    } else if (std.mem.eql(u8, arg, "--lang")) {
      lang_str_opt = args.next();
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
    try stdout.flush();
    std.process.exit(0);
  }

  const lang_out: LanguageOption = if (lang_str_opt) |lang_str|
    if (std.mem.eql(u8, lang_str, "zig"))
      .zig
    else if (std.mem.eql(u8, lang_str, "c"))
      .c
    else
      {
        var backing: [1024]u8 = undefined;
        var stdout = Io.File.stdout().writer(io, &backing);

        try stdout.interface.print("Invalid language output option: {s}\n", .{ lang_str });
        try stdout.interface.print(UsageMsgFmt, .{program_name});
        try stdout.flush();
        std.process.exit(1);
      }
  else
    .zig;

  const tree_gen_fn: GenerateCodeTreeFn,
  const code_write_fn: WriteCodeToFileFn = switch (lang_out) {
    .zig => .{ Zig.generate_code_tree, Zig.write_code_to_file },
    .c =>   .{ C.generate_code_tree, C.write_code_to_file },
  };

  var buf: [1024]u8 = undefined;
  var out: Io.File.Writer = out: {
    const out_file = if (out_path_opt) |out_path|
      if (std.mem.eql(u8, out_path, "cli"))
        Io.File.stdout()
      else
        try cwd.createFile(
          io,
          out_path,
          .{},
        )
    else
      Io.File.stdout();

    break :out out_file.writerStreaming(io, &buf);
  };
  const out_writer = &out.interface;

  var cur_protocol_file_opt: ?*EntryNode = first_protocol_file_opt;
  var output: Output = .{};
  while (cur_protocol_file_opt) |cur_protocol_file| {
    cur_protocol_file_opt = cur_protocol_file.next;
    if (debug) std.debug.print(
      "reading protocol file :: {s}\n",
      .{ cur_protocol_file.name },
    );
    try tree_gen_fn(
      io,
      allocator,
      &output,
      cur_protocol_file.name,
    );
  }

  if (debug) std.debug.print("found {} protocols!\n", .{output.protocol_count});

  try code_write_fn(
    out_writer,
    &output,
    debug,
  );

  try out.flush();
}

fn fetch_entry_data_lang(
  arena: std.mem.Allocator,
  entry_prefix: []const u8,
  entry: *EntryNode,
  element: *const Xml.Element,
  @"type": EntryType,
  lang: LanguageOption,
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
    entry_prefix,
    entry_name,
    entry_type,
    lang,
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
          try toIdentifier(arena, "struct ", entry_interface.?, .arg, lang)
        else if (data_type == .uint and enum_t != null)
          try toIdentifier(arena, entry_prefix, enum_t.?, .@"enum", lang)
        else
          if (lang == .zig)
            data_type.zigTypeString()
          else
            data_type.cTypeString(),
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

const Output = struct {
  protocol_first: ?*EntryNode = null,
  protocol_last: ?*EntryNode = null,
  protocol_count: u32 = 0,
};

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

  pub fn cTypeString(data_type: DataType) []const u8 {
    return switch (data_type) {
      .destructor, .invalid => @typeName(void),
      .uint, .object, .new_id => "wl_uint",
      .int => "wl_int",
      .fd => "wl_fd",
      .fixed => "wl_float",
      .array => "struct wl_array",
      .string => "struct wl_string",
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

const LanguageOption = enum {
  zig,
  c,
};

const GenerateCodeTreeFn = *const fn (
    io: Io,
    arena: std.mem.Allocator,
    output: *Output,
    spec_filename: []const u8,
) anyerror!void;

const WriteCodeToFileFn = *const fn (
    writer: *Io.Writer,
    code_tree: *Output,
    debug: bool,
) anyerror!void;

/// Namespace for Code tree building & Code output generation for Zig
const Zig = struct {
  pub fn generate_code_tree(
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

    sll_push_end(
      protocol,
      &output.protocol_first,
      &output.protocol_last,
      &output.protocol_count,
    );

    var spec_interfaces = spec.root.findChildrenByTag("interface");
    while (spec_interfaces.next()) |spec_interface| {
      const interface = try arena.create(EntryNode);
      sll_push_end(
        interface,
        &protocol.interface_first,
        &protocol.interface_last,
        &protocol.interface_count,
      );
      try fetch_entry_data(arena, interface, spec_interface, .interface);

      var spec_interface_enums = spec_interface.findChildrenByTag("enum");
      while (spec_interface_enums.next()) |spec_interface_enum| {
        const @"enum" = try arena.create(EntryNode);
        sll_push_end(
          @"enum",
          &interface.enum_first,
          &interface.enum_last,
          &interface.enum_count,
        );
        try fetch_entry_data(arena, @"enum", spec_interface_enum, .@"enum");

        var enum_entries = spec_interface_enum.findChildrenByTag("entry");
        while (enum_entries.next()) |enum_entry| {
          const entry = try arena.create(EntryNode);
          sll_push_end(
            entry,
            &@"enum".arg_first,
            &@"enum".arg_last,
            &@"enum".arg_count,
          );
          try fetch_entry_data(arena, entry, enum_entry, .@"arg");
        }
      }

      var spec_interface_events = spec_interface.findChildrenByTag("event");
      while (spec_interface_events.next()) |spec_interface_event| {
        const event = try arena.create(EntryNode);
        sll_push_end(
          event,
          &interface.event_first,
          &interface.event_last,
          &interface.event_count,
        );
        try fetch_entry_data(arena, event, spec_interface_event, .event);

        var event_entries = spec_interface_event.findChildrenByTag("arg");
        while (event_entries.next()) |event_entry| {
          const entry = try arena.create(EntryNode);
          sll_push_end(
            entry,
            &event.arg_first,
            &event.arg_last,
            &event.arg_count,
          );
          try fetch_entry_data(arena, entry, event_entry, .@"arg");
        }
      }

      var request_opcode: u16 = 0;
      var spec_interface_requests = spec_interface.findChildrenByTag("request");
      while (spec_interface_requests.next()) |spec_interface_request| : (request_opcode += 1) {
        const request = try arena.create(EntryNode);
        sll_push_end(
          request,
          &interface.request_first,
          &interface.request_last,
          &interface.request_count,
        );
        try fetch_entry_data(arena, request, spec_interface_request, .request);
        request.opcode = request_opcode;
        request.arg_type = "void";

        var request_args = spec_interface_request.findChildrenByTag("arg");
        while (request_args.next()) |request_arg| {
          const arg = try arena.create(EntryNode);
          sll_push_end(
            arg,
            &request.arg_first,
            &request.arg_last,
            &request.arg_count,
          );
          try fetch_entry_data(arena, arg, request_arg, .@"arg");
          if (arg.data_type == .new_id) {
            if (arg.interface == null) {
              request.arg_type = "InterfaceT";
            } else {
              request.arg_type = arg.interface;
            }
          }
        }
      }
    }
  }

  pub fn write_code_to_file(
    writer: *Io.Writer,
    code_tree: *Output,
    debug: bool,
  ) !void {
    var protocol_opt: ?*EntryNode = code_tree.protocol_first;
    try writer.print(OutputBeginString, .{});
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
      _ = try writer.write(CombinedEnumBeginString);
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
      _ = try writer.write(CombinedEnumEndString);
    }

    // Write Combined Event Union
    {
      _ = try writer.write(CombinedEventBeginString);
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
      _ = try writer.write(CombinedEventEndString);
    }

    // Write Combined Object Union
    {
      _ = try writer.write(CombinedInterfaceBeginString);
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
      _ = try writer.write(CombinedInterfaceEndString);
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
        _ = try writer.write(MessageDecodeBeginString);
        message_opt = wl_interface.event_first;
        var opcode: u16 = 0;
        while (message_opt) |wl_event| : (message_opt = wl_event.next) {
          defer opcode += 1;
          try writer.print("        {d} => {{\n", .{opcode});
          try write_wl_message_decode(writer, wl_interface.name, wl_event);
          try writer.print("        }},\n", .{});
        }
        _ = try writer.write(MessageDecodeEndString);
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
      MessageEncodeBeginString,
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
    _ = try writer.write(MessageEncodeEndString);
  }

  fn write_wl_message_decode(
    writer: *Io.Writer,
    wl_interface_name: []const u8,
    wl_message: *EntryNode,
  ) !void {
    var arg_opt: ?*EntryNode = wl_message.arg_first;
    _ = try writer.write(MessageDecodeArgsBeginString);
    while (arg_opt) |arg| : (arg_opt = arg.next) {
      const arg_undef = switch (arg.type) {
        else => "undefined",
      };
      _ = try writer.print(MessageDecodeArgsEntryFmt, .{ @tagName(arg.data_type), arg_undef });
    }
    _ = try writer.write(MessageDecodeArgsEndString);
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

  fn fetch_entry_data(
    arena: std.mem.Allocator,
    entry: *EntryNode,
    element: *const Xml.Element,
    @"type": EntryType,
  ) !void {
    try fetch_entry_data_lang(arena, "", entry, element, @"type", .zig);
  }

  const MessageDecodeBeginString =
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
  const MessageDecodeArgsBeginString =
  \\          var args_in = [_]MessageArg{
  \\
  ;
  const MessageDecodeArgsEntryFmt =
  \\            .{{ .{s} = {s} }},
  \\
  ;
  const MessageDecodeArgsEndString =
  \\          };
  \\
  ;
  const MessageDecodeEndString =
  \\        else => @panic("Invalid Opcode"),
  \\      }
  \\    };
  \\  }
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

  const MessageEncodeBeginString =
  \\    proxy.message_encode(
  \\      self.toInt(),
  \\      Opcode,
  \\      &.{
  \\
  ;
  const MessageEncodeEndString =
  \\      },
  \\    );
  \\
  ;

  const CombinedInterfaceBeginString =
  \\pub const Object = union (enum) {
  \\
  ;
  const CombinedInterfaceEntryFmt =
  \\  {s}: {s},
  \\
  ;
  const CombinedInterfaceEndString =
  \\};
  \\
  ;

  const CombinedEventBeginString =
  \\pub const Event = union (enum) {
  \\  invalid: void,
  \\
  ;
  const CombinedEventEntryFmt =
  \\  {s}_{s}: {s}.{s},
  \\
  ;
  const CombinedEventEndString =
  \\};
  \\
  ;

  const CombinedEnumBeginString =
  \\pub const Enum = union (enum) {
  \\  invalid: void,
  \\
  ;
  const CombinedEnumEntryFmt =
  \\  {s}_{s}: {s}.{s},
  \\
  ;
  const CombinedEnumEndString =
  \\};
  \\
  ;

  const LogPaste =
  \\const log = @import("std").log.scoped(.WaylandProtocols);
  \\
  ;

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
};

/// Namespace for Code tree building & Code output generation for C-header
const C = struct {
  fn generate_code_tree(
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
    try fetch_entry_data(arena, "", protocol, spec.root, .protocol);

    sll_push_end(
      protocol,
      &output.protocol_first,
      &output.protocol_last,
      &output.protocol_count,
    );

    var spec_interfaces = spec.root.findChildrenByTag("interface");
    while (spec_interfaces.next()) |spec_interface| {
      const interface = try arena.create(EntryNode);
      try fetch_entry_data(arena, "", interface, spec_interface, .interface);
      sll_push_end(
        interface,
        &protocol.interface_first,
        &protocol.interface_last,
        &protocol.interface_count,
      );

      var spec_interface_enums = spec_interface.findChildrenByTag("enum");
      while (spec_interface_enums.next()) |spec_interface_enum| {
        const @"enum" = try arena.create(EntryNode);
        try fetch_entry_data(arena, interface.name, @"enum", spec_interface_enum, .@"enum");
        sll_push_end(
          @"enum",
          &interface.enum_first,
          &interface.enum_last,
          &interface.enum_count,
        );

        var enum_entries = spec_interface_enum.findChildrenByTag("entry");
        while (enum_entries.next()) |enum_entry| {
          const entry = try arena.create(EntryNode);
          try fetch_entry_data(arena, "", entry, enum_entry, .@"arg");
          sll_push_end(
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
        try fetch_entry_data(arena, interface.name, event, spec_interface_event, .event);
        sll_push_end(
          event,
          &interface.event_first,
          &interface.event_last,
          &interface.event_count,
        );

        var event_entries = spec_interface_event.findChildrenByTag("arg");
        while (event_entries.next()) |event_entry| {
          const entry = try arena.create(EntryNode);
          try fetch_entry_data(arena, interface.name, entry, event_entry, .@"arg");
          sll_push_end(
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
        try fetch_entry_data(arena, interface.name, request, spec_interface_request, .request);
        request.opcode = request_opcode;
        request.arg_type = "void";
        sll_push_end(
          request,
          &interface.request_first,
          &interface.request_last,
          &interface.request_count,
        );

        var request_args = spec_interface_request.findChildrenByTag("arg");
        while (request_args.next()) |request_arg| {
          const arg = try arena.create(EntryNode);
          // TODO: Think through how this plays out to get in-interface types referenced properly
          // Reference point to see if working: zwp_linus_buffer_params_v1_create_immed(... <type> flags);
          const prefix = try std.fmt.allocPrint(local_allocator, "{s}_", .{interface.name});
          try fetch_entry_data(arena, prefix, arg, request_arg, .@"arg");
          if (arg.data_type == .new_id) {
            if (arg.interface == null) {
              request.arg_type = "InterfaceT";
            } else {
              request.arg_type = try std.fmt.allocPrint(arena, "struct {s}", .{arg.interface.?});
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

  pub fn write_code_to_file(
    writer: *Io.Writer,
    code_tree: *Output,
    debug: bool,
  ) !void {
    var protocol_opt: ?*EntryNode = code_tree.protocol_first;
    var interface_opt: ?*EntryNode = code_tree.protocol_first;
    try writer.print(OutputBeginString, .{});

    // Struct Forward declarations
    {
      protocol_opt = code_tree.protocol_first;
      defer protocol_opt = code_tree.protocol_first;

      _ = try writer.write(DeclarationBeginString);
      _ = try writer.write(BaseTypesCodePaste);
      while (protocol_opt) |protocol| : (protocol_opt = protocol.next) {
        if (debug) std.debug.print(
          "found {} interfaces in protocol {s}!\n",
          .{
            protocol.interface_count,
            protocol.name,
          },
        );
        interface_opt = protocol.interface_first;
        while (interface_opt) |interface| : (interface_opt = interface.next) {
          try writer.print(InterfaceDeclareFmt, .{interface.name});
          var enum_opt: ?*EntryNode = interface.enum_first;
          while (enum_opt) |@"enum"| : (enum_opt = @"enum".next) {
            try writer.print(EnumDeclareFmt, .{ interface.name, @"enum".name} );
          }
        }
      }
    }

    // Struct and Enum definitions and Request / Event declarations
    {
      protocol_opt = code_tree.protocol_first;
      defer protocol_opt = code_tree.protocol_first;
      while (protocol_opt) |protocol| : (protocol_opt = protocol.next) {
        interface_opt = protocol.interface_first;
        while (interface_opt) |interface| : (interface_opt = interface.next) {
          try writer.print(InterfaceDefinitionFmt, .{ interface.name, interface.name, interface.name });
          var enum_opt: ?*EntryNode = interface.enum_first;
          while (enum_opt) |@"enum"| : (enum_opt = @"enum".next) {
            try writer.print(EnumBeginFmt, .{ interface.name, @"enum".name} );
            var enum_field_opt: ?*EntryNode = @"enum".arg_first;
            while (enum_field_opt) |field| : (enum_field_opt = field.next) {
              try writer.print(EnumEntryFmt, .{interface.name, @"enum".name, field.name, field.value.? });
            }
            _ = try writer.write(EnumEndString);
          }

          var message_opt: ?*EntryNode = interface.request_first;
          while (message_opt) |message| : (message_opt = message.next) {
            try writer.print(RequestDeclareBeginFmt, .{message.arg_type.?, interface.name, message.name});
            var arg_opt: ?*EntryNode = message.arg_first;
            while (arg_opt) |arg| : (arg_opt = arg.next) {
              try writer.print(RequestDeclareArgFmt, .{ arg.arg_type.?, arg.name });
            }
            _ = try writer.write(RequestDeclareEndString);
          }

          _ = try writer.write(InterfaceDefinitionSectionEndString);
        }
      }
    }

    // Typedefs
    {
      protocol_opt = code_tree.protocol_first;
      defer protocol_opt = code_tree.protocol_first;
      _ = try writer.write(StructTypedefsBegin);
      while (protocol_opt) |protocol| : (protocol_opt = protocol.next) {
        interface_opt = protocol.interface_first;
        while (interface_opt) |interface| : (interface_opt = interface.next) {
          try writer.print(StructTypedefEntryFmt, .{interface.name, interface.name});
        }
      }
      _ = try writer.write(StructTypedefsEnd);
      _ = try writer.write(DeclarationEndString);
    }

    // Implementations
    {
      protocol_opt = code_tree.protocol_first;
      defer protocol_opt = code_tree.protocol_first;
      _ = try writer.write(ImplementationBeginString);
      while (protocol_opt) |protocol| : (protocol_opt = protocol.next) {
      }
      _ = try writer.write(ImplementationEndString);
    }
  }

  fn fetch_entry_data(
    arena: std.mem.Allocator,
    prefix: []const u8,
    entry: *EntryNode,
    element: *const Xml.Element,
    @"type": EntryType,
  ) !void {
    try fetch_entry_data_lang(arena, prefix, entry, element, @"type", .c);
  }

  // Enum forward-declarations
  // {interface_name}_{enum_name}
  const EnumDeclareFmt =
  \\typedef wl_uint {s}_{s};
  \\
  ;

  // Enum Definitions
  // {interface_name}_{enum_name}
  const EnumBeginFmt =
  \\enum {s}_{s} {{
  \\
  ;
  // Enumn Entry Format
  // {interface_name}_{enum_name}_{entry_name} = {value},
  const EnumEntryFmt =
  \\  {s}_{s}_{s} = {s},
  \\
  ;
  const EnumEndString =
  \\};
  \\
  ;

  const RequestDeclareBeginFmt =
  \\{s}
  \\{s}_{s}(
  \\  struct wl_proxy *restrict proxy
  ;
  const RequestDeclareArgFmt =
  \\,
  \\  {s} {s}
  ;
  const RequestDeclareEndString =
  \\
  \\);
  \\
  ;

  // Interface struct forward-declarations
  const InterfaceDeclareFmt =
  \\struct {s};
  \\
  \\
  ;

  const InterfaceDefinitionSectionBeginFmt =
  \\ //-----------------------------------------------------------------------------
  \\ // BEGIN {s} {s}
  \\ //-----------------------------------------------------------------------------
  \\
  ;

  const InterfaceDefinitionSectionEndString =
  \\ //-----------------------------------------------------------------------------
  \\
  ;

  // Interface struct definitions
  const InterfaceDefinitionFmt =
  \\struct {s} {{
  \\  wl_uint id;
  \\}};
  \\const struct wl_string {s}_Name =
  \\  WL_STRING_LITERAL("{s}");
  \\
  \\
  ;

  const StructDeclareFmt =
  \\struct {s};
  \\
  ;

  const StructTypedefsBegin =
  \\#ifdef WL_TYPEDEF_STRUCTS
  \\/* Base Wayland Type Structs */
  \\typedef struct wl_array wl_array;
  \\typedef struct wl_string wl_string;
  \\typedef struct wl_object wl_object;
  \\typedef struct wl_proxy wl_proxy;
  \\typedef struct wl_event wl_event;
  \\
  \\/* Wayland Interface Type Structs */
  \\
  ;
  const StructTypedefEntryFmt =
  \\typedef struct {s} {s};
  \\
  ;
  const StructTypedefsEnd =
  \\#endif /* Struct Typedefs End */
  \\
  ;

  // General base types
  const BaseTypesCodePaste =
  \\/* Wayland Interaction Base Types */
  \\typedef unsigned int wl_uint;
  \\typedef int wl_int;
  \\typedef int wl_fd;
  \\typedef float wl_float;
  \\struct wl_array {
  \\  unsigned char *ptr;
  \\  wl_uint len;
  \\};
  \\struct wl_string {
  \\  char *ptr;
  \\  wl_uint len;
  \\};
  \\#define WL_STRING_LITERAL(s) \
  \\  (struct wl_string) { .ptr = (char*)s, .len = sizeof(s) - 1 }
  \\
  \\typedef wl_uint wl_object_tag; /* enum of all interface_types */
  \\struct wl_object; /* Will be union type of all interfaces */
  \\
  \\typedef wl_uint wl_event_tag;
  \\struct wl_event;
  \\
  \\struct wl_proxy {
  \\  /* TODO: Flesh this out, lol */
  \\};
  \\
  \\
  ;

  const DeclarationBeginString =
  \\#ifndef WL_PROTOCOLS_H
  \\#define WL_PROTOCOLS_H
  \\
  \\#ifdef __cplusplus
  \\extern "C" {
  \\#endif
  \\
  ;
  const DeclarationEndString =
  \\
  \\#undef WL_STRING_LITERAL
  \\#ifdef __cplusplus
  \\}
  \\#endif
  \\
  \\#endif /* Protocols Declaration End */
  \\
  ;
  const ImplementationBeginString =
  \\#ifdef WL_PROTOCOLS_IMPLEMENTATION
  \\#ifdef __cplusplus
  \\extern "C" {
  \\#endif
  \\
  ;
  const ImplementationEndString =
  \\
  \\#ifdef __cplusplus
  \\}
  \\#endif
  \\#endif /* Protocols Implementation End */
  \\
  ;
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
  prefix: []const u8, // this is only used when generating C code
  string: []const u8,
  entry_type: EntryType,
  lang: LanguageOption,
) ![]const u8 {
  std.debug.assert(string.len > 0);
  const name = name: {
    if (lang == .zig) {
      if (entry_type == .@"enum" or entry_type == .bitfield) {
        break :name try snake_to_pascal(allocator, string);
      }

      if (is_digit(string[0]) or Keywords.has(string)) {
        break :name try std.fmt.allocPrint(allocator, "@\"{s}\"", .{ string });
      }

      break :name try allocator.dupe(u8, string);
    } else if (lang == .c) {

      const namespace_end = nse: {
        for (string, 0..) |char, idx| {
          if (char == '.') break :nse idx;
        }
        break :nse 0;
      };
      if ((entry_type != .@"enum" and entry_type != .bitfield) or namespace_end == 0) {
        var new = try allocator.alloc(u8, string.len + prefix.len);
        @memcpy(new[0..prefix.len], prefix);
        @memcpy(new[prefix.len..], string);
        for (new, 0..) |char, idx| {
          if (char == '.') new[idx] = '_';
        }
        break :name new;
      } else {
        var new = try allocator.dupe(u8, string);
        for (new, 0..) |char, idx| {
          if (char == '.') new[idx] = '_';
        }
        break :name new;
      }
    }
    unreachable;
  };
  return name;
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
\\  -o --out <name> Output file to write to.
\\                  If no file is provided output will be written to STDOUT.
\\  --lang <name>   Output language -- must be either "zig" or "c"
\\  --debug         Debug info printing.
\\
;

const OutputBeginString =
\\//  This file is generated from provided Wayland XML specifications by
\\//  wl-protocol-codegen and should NOT be edited manually.
\\
;

const Io = std.Io;
const Keywords = std.zig.Token.keywords;

const Xml = @import("xml.zig");
const std = @import("std");
