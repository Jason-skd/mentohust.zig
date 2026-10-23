const clap = @import("clap");
const rj = @import("rj-connect");

test "locked dependencies expose their package contracts" {
    _ = comptime clap.parseParamsComptime(
        \\-h, --help  Display help.
        \\
    );
    _ = rj.session.Session;
}
