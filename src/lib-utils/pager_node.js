// Provides: wax_pager_capture_stdout
function wax_pager_capture_stdout() {
  var fs = require("fs");
  var child_process = require("child_process");
  var pager = globalThis.process.env.PAGER || "less -RFX";

  var child = child_process.spawn("/bin/sh", ["-c", pager], {
    stdio: ["pipe", "inherit", "inherit"]
  });

  child.on("error", function() {});

  var orig_writeSync = fs.writeSync;
  fs.writeSync = function (fd, buffer, offset, length, position) {
    if (fd === 1) {
      if (typeof buffer === "string") {
        child.stdin.write(buffer);
        return require("buffer").Buffer.byteLength(buffer);
      } else {
        var buf = require("buffer").Buffer.from(buffer.slice(offset, offset + length));
        child.stdin.write(buf);
        return length;
      }
    }
    return orig_writeSync.apply(this, arguments);
  };

  var orig_stdout_write = globalThis.process.stdout.write;
  globalThis.process.stdout.write = function (chunk, encoding, cb) {
    return child.stdin.write(chunk, encoding, cb);
  };

  var orig_exit = globalThis.process.exit;
  globalThis.process.exit = function(code) {
    child.stdin.end();
    // Prevent multiple exits
    globalThis.process.exit = function() {};
    child.on("exit", function() {
      orig_exit.call(globalThis.process, code);
    });
  };

  globalThis._wax_pager_state = {
    child: child,
    orig_writeSync: orig_writeSync,
    orig_stdout_write: orig_stdout_write,
    orig_exit: orig_exit
  };
  return 0;
}

// Provides: wax_pager_flush_captured
function wax_pager_flush_captured() {
  var state = globalThis._wax_pager_state;
  if (!state) return 0;
  var fs = require("fs");
  fs.writeSync = state.orig_writeSync;
  globalThis.process.stdout.write = state.orig_stdout_write;
  // Note: we leave process.exit overridden so it waits for the pager if an exit happens later
  globalThis._wax_pager_state = null;

  state.child.stdin.end();
  return 0;
}
