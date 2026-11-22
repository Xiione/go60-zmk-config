# MoErgo Go60 Custom Configuration for ZMK

![MoErgo Logo](moergo_logo.png)

This repo is the official ZMK configuration of the MoErgo Go60 wireless split keyboard. Use it to develop your own keymap and easily build your own ZMK firmware to run on your Go60.

**NOTE: You can also customize the layout of your Go60 keyboard with the Go60 Layout Editor webapp. For most users Go60 Layout Editor is the recommended and simpler option. More information is available at the official MoErgo Go60 Support site (see resources below).**

These steps will get you using your keymap on your keyboard in the fastest time possible. It uses the GitHub Actions feature to build your firmware online.

If you are looking to dig deeper into ZMK and develop new functionality, it is recommended to follow the steps of installing ZMK as found on the official ZMK documentation site (linked below).

## Custom layout

This configuration uses the Enthium v15a typing layout from
[sunaku's development snapshot](https://my.moergo.com/glove80/#/layout/user/a590b975-1dde-4354-b118-25f0d8dbc87b),
adapted to Go60:

```text
       Q Y U O ;     X L D P Z
     B C I E A ,     K H T N S W
 Shift ' - = . /     J M G F V Shift
```

The six thumb keys retain their existing tap/hold assignments, shown left to right:

```text
Left:  Tab/Number    Space/Cursor    Esc/Function
Right: Enter/System R/Symbol        Backspace/Mouse
```

Home row modifiers stay on the same fingers, so the left middle finger now taps E
and the left index taps A. The extra-row parentheses and brackets, combos,
and the 130 ms tapping resolution are retained. Keyboard
mouse-emulation Fast speed is 3x, and Function has Play/Pause beside Previous/Next.

Moving the right trackpad activates Mouse_auto for 300 ms. The first two left
thumb keys glow gold and send right-click and left-click, respectively. All
other keys and lighting inherit from the active layers underneath.

`config/go60.keymap` is the firmware source; `go60-editor.json` contains the matching
v15a typing bindings for import into the Go60 Layout Editor. After flashing, check
ordinary typing, Typing mode, macOS modifiers, thumb rolls, and common programming
punctuation before judging comfort and speed.

## Regenerating the editor export

Initialize the repository's pinned submodules after cloning:

```sh
git submodule update --init --recursive
```

Successful `./build.sh` runs regenerate `go60-editor.json` automatically after
building the firmware. To export without building firmware, run:

```sh
./export-editor-json.sh
```

The standalone exporter works from any working directory. It requires Rust/Cargo,
`clang`, `jq`, `uuidgen`, and `trash` on the host. Existing UUID and date fields are
reused to avoid metadata-only changes; a missing export receives fresh metadata.
Generation failures preserve the previous export and cause `build.sh` to fail.
Incremental builds and GitHub Actions retain their existing behavior.

The exporter comes from `tools/zmk-layout-rs`, pinned to a commit on the fork's
`xiione/go60-editor-export` branch. Builds do not fetch or advance that pin;
updating the submodule is an explicit maintenance step. Keep `go60-editor.json`
under version control alongside the keymap.

## Resources
- The [official MoErgo Go60 Support](https://moergo.com/go60-support) web site. Go60 documentation and other technical resources.
- The [official MoErgo Discord Server](https://moergo.com/discord). Instant conversations with other Go60 users.

- The [official ZMK Documentation](https://zmk.dev/docs) web site. Find the answers to many of your questions about ZMK Firmware.
- The [official ZMK Discord Server](https://discord.gg/8cfMkQksSB). Instant conversations with other ZMK developers and users. Great technical resource!

- The [official MoErgo ZMK Distribution](https://github.com/moergo-sc/zmk). Repository for ZMK firmware customized for Go60 and Glove80.

## Instructions
1. Log into, or sign up for, your personal GitHub account.
2. Create your own repository using this repository as a template ([instructions](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template)) and check it out on your local computer.
3. Edit the keymap file(s) to suit your needs
4. Commit and push your changes to your personal repo. Upon pushing it, GitHub Actions will start building a new version of your firmware with the updated keymap.

## Firmware Files
To locate your firmware files and reflash your Go60...
1. log into GitHub and navigate to your personal config repository you just uploaded your keymap changes to.
2. Click "Actions" in the main navigation, and in the left navigation click the "Build" link.
3. Select the desired workflow run in the centre area of the page (based on date and time of the build you wish to use). You can also start a new build from this page by clicking the "Run workflow" button.
4. After clicking the desired workflow run, you should be presented with a section at the bottom of the page called "Artifacts". This section contains the results of your build, in a file called "go60.uf2"
5. Download the go60.uf2
6. Flash the firmware to Go60 according to the user documentation on the official Go60 Support website (linked above)

Your keyboard is now ready to use.
