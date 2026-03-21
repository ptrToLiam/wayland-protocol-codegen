pub fn build(b: *std.Build) !void {
  const target = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});

  const protocols_opt = b.option(
    []std.Build.LazyPath,
    "protocols",
    "Paths to desired wayland protocols (e.g. wayland.xml, xdg-shell.xml, etc.)"
  );

  const debug_opt = b.option(
    bool,
    "debug",
    "run generator with debug logging"
  ) orelse false;

  const root = b.createModule(.{
    .root_source_file = b.path("src/generator.zig"),
    .target = target,
    .optimize = optimize
  });

  const generator = b.addExecutable(.{
    .name = "wl-protocol-codegen",
    .root_module = root,
  });
  b.installArtifact(generator);

  if (protocols_opt) |protocols| {
    const wl_generate_cmd = b.addRunArtifact(generator);

    for (protocols) |protocol| {
      wl_generate_cmd.addFileArg(protocol);
    }

    if (debug_opt) wl_generate_cmd.addArg("--debug");
    wl_generate_cmd.addArg("-o");
    const protocols_zig = wl_generate_cmd.addOutputFileArg("protocols.zig");

    const protocols_zig_module = b.addModule("wayland-protocols", .{
      .root_source_file = protocols_zig,
    });
    _ = protocols_zig_module;
  }
}

const std = @import("std");
