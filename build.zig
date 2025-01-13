const std = @import("std");

const release_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
};
const release_optimization = std.builtin.OptimizeMode.ReleaseSafe;
const exe_name = "godot-wsl-proxy";
// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Special step to make application to all the supported platforms
    const release_step = b.step("release", "Release executables on all the supported envs");
    for (release_targets) |release_target| {
        const release_exe = b.addExecutable(.{
            .name = exe_name,
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(release_target),
            .optimize = release_optimization,
            .linkage = .static,
        });
        const install_dir = try release_target.zigTriple(b.allocator);
        const target_output = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = install_dir,
                },
            },
        });
        const tar_gz_file = try std.fmt.allocPrint(b.allocator, "{s}-{s}.tar.gz", .{ exe_name, install_dir });
        const tar_gz_tool = b.addSystemCommand(&.{"tar"});
        tar_gz_tool.setCwd(std.Build.LazyPath{ .cwd_relative = b.getInstallPath(target_output.dest_dir.?, "") });
        tar_gz_tool.addArg("-czf");
        tar_gz_tool.addArg(tar_gz_file);
        tar_gz_tool.addArg(exe_name);

        const sha256_file = try std.fmt.allocPrint(b.allocator, "{s}.sha256", .{tar_gz_file});
        const sha256_tool = b.addSystemCommand(&.{"sha256sum"});
        sha256_tool.setCwd(std.Build.LazyPath{ .cwd_relative = b.getInstallPath(target_output.dest_dir.?, "") });
        sha256_tool.addArg("-b");
        sha256_tool.addArg(tar_gz_file);
        const sha256_save = b.addInstallFileWithDir(sha256_tool.captureStdOut(), target_output.dest_dir.?, sha256_file);

        tar_gz_tool.step.dependOn(&target_output.step);
        sha256_tool.step.dependOn(&tar_gz_tool.step);
        sha256_save.step.dependOn(&sha256_tool.step);

        release_step.dependOn(&sha256_save.step);
    }
}
