An [rmpcd](https://rmpc.mierak.dev/rmpcd/) plugin for scrobbling to LibreFM. Based on the built-in [LastFM scrobbling plugin](https://github.com/mierak/rmpc/blob/master/rmpcd/src/lua/builtin/lastfm.lua).

### Why?

The [rmpcd documentation](https://rmpc.mierak.dev/rmpcd/) includes a plugin for scrobbling to Last.fm. I wanted to support scrobbling to Libre.fm, so I wrote a copy of the plugin to do that. In addition to scrobbling plays, this plugin includes an option to update the "now playing" section on your Libre.fm profile.

### Instructions

To use this plugin:

1. Install [rmpcd](https://rmpc.mierak.dev/rmpcd/) and run `rmpcd init` to get an `init.lua` file.
2. Go to the place where `init.lua` was saved (probably `$HOME/.config/rmpcd/`) and create a `plugins` folder if it doesn't already exist.
3. Clone this repository and copy the `playcount.lua` file into your `$HOME/.config/rmpcd/plugins/` folder.
4. [Get an API key for Libre.fm](https://libre.fm/api-keys.php).
5. Add the following lines to your `init.lua` file to install the plguin:
    ```lua
    rmpcd.install("plugins/librefm"):setup({
      api_key = "<libre_fm_api_key>",
      shared_secret = "<libre_fm_secret>",
      update_now_playing = true,
    })
    ```

### License

BSD 3-Clause open-source license; see [LICENSE](LICENSE) for complete copyright and license statement.
