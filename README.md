# Finally... 
a 32/64 bit compatible Quartz Composer composition compatible screensaver for MacOS Mojave!

# But thats not all!
It also has an interactive mode by default, so you can do stuff with compositions at fullscreen with mouse and keyboard interaction! <br>
So it doubles as a viewing application for your 32bit and 64bit compositions on Mojave 10.14.6 <3

Shame this wasn't a option by default, but here we are.

# Command-line Flags:

`--debug` <br>
Enables verbose logging to console. 
- Default: off.

`--comp <path> or --comp=<path>` <br>
Path to the .qtz composition to load. Relative paths are resolved relative to the executable’s directory.
  - Default: if omitted, it tries to load Default.qtz from the app bundle; if that fails, the app alerts and (in interactive mode) quits.

`--screensaver <seconds> or --screensaver=<seconds>` <br>
Enable saver mode. Shows the composition only after Quartz reports continuous idle for the given number of seconds; hides the cursor while showing; any mouse activity dismisses it.
  - Alias: --ss <seconds> / --ss=<seconds>.
  - If you pass 0 or a non-positive value, it falls back to 300s.
Default: disabled (interactive mode).

`--ss-keys` <br>
In saver mode, also dismiss on any key (not just mouse). Uses a local key monitor and, if permitted, a global CGEvent tap (Accessibility permission).
  - Default: off.

`--any-key` <br>
In interactive mode, any key will quit the app (otherwise only Esc or Cmd+Q quit).
  - Default: off.

`--quit-on-mouse` <br>
In interactive mode, any mouse movement/click/scroll quits the app.
  - Default: off.

`--auto-quit <seconds> or --auto-quit=<seconds>` <br>
In interactive mode, auto-quit after the specified number of seconds.
  - Default: disabled.

# Important note:
Before running the app, Please go to <br> 
`System Preferences > Security & Privacy > Accesibility >` ... And then add QCRunner here. <br>
It needs this permission to be able to read mouse/keyboard input. <br>
If you are using a quartz composition that uses camera or microphone input, <br> 
and for some reason your system does not request permission, try using [this script](https://gist.github.com/g-l-i-t-c-h-o-r-s-e/fe1e3215cde369806c9fef50e3b15b30) <br> I made to manually force these permissions for any application.
