// Provides: wax_pager_capture_stdout
function wax_pager_capture_stdout() {
  var fs = require("fs");
  var child_process = require("child_process");
  var pager = globalThis.process.env.PAGER ||
    (globalThis.process.platform === "win32" ? "more" : "less -RFX");

  // shell: true runs the command string through the system shell (/bin/sh on
  // Unix, cmd on Windows), mirroring the native Unix.open_process_out.
  var child = child_process.spawn(pager, {
    stdio: ["pipe", "inherit", "inherit"],
    shell: true
  });

  child.on("error", function() {});

  // A pager that quits early (e.g. `q` in less) closes its end of the pipe;
  // without a handler the resulting EPIPE surfaces as an uncaught stream
  // error. Once broken, later writes are silently dropped — the behaviour a
  // native pipeline gets by ignoring SIGPIPE.
  var broken = false;
  child.stdin.on("error", function() { broken = true; });
  var forward = function(chunk, encoding, cb) {
    if (broken) {
      if (cb) cb();
      return true;
    }
    try {
      return child.stdin.write(chunk, encoding, cb);
    } catch (e) {
      broken = true;
      if (cb) cb();
      return true;
    }
  };

  var orig_writeSync = fs.writeSync;
  fs.writeSync = function (fd, buffer, offset, length, position) {
    if (fd === 1) {
      if (typeof buffer === "string") {
        forward(buffer);
        return require("buffer").Buffer.byteLength(buffer);
      } else {
        var buf = require("buffer").Buffer.from(buffer.slice(offset, offset + length));
        forward(buf);
        return length;
      }
    }
    return orig_writeSync.apply(this, arguments);
  };

  var orig_stdout_write = globalThis.process.stdout.write;
  globalThis.process.stdout.write = function (chunk, encoding, cb) {
    return forward(chunk, encoding, cb);
  };

  // Track the pager's exit: the override below must not wait for an "exit"
  // event that has already fired (an early-quit pager would leave the
  // process hanging).
  var exited = false;
  child.on("exit", function() { exited = true; });

  var orig_exit = globalThis.process.exit;
  globalThis.process.exit = function(code) {
    try { child.stdin.end(); } catch (e) {}
    // Prevent multiple exits
    globalThis.process.exit = function() {};
    if (exited) return orig_exit.call(globalThis.process, code);
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

  try { state.child.stdin.end(); } catch (e) {}
  return 0;
}
