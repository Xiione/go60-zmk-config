{ firmware, pkgs ? import /src/nix/pinned-nixpkgs.nix {} }:
let
  config = ../../config;
  upstream = firmware.zephyr.modules.cirque-input-module.src;
  probe = pkgs.runCommand "cirque-input-module" {} ''
    cp -R ${upstream} $out
    chmod -R u+w $out
    patch -d $out -p1 < ${./pinnacle.patch}
    cp ${./pad_probe.h} $out/drivers/input/pad_probe.h
  '';
  build = side:
    let
      keymap = pkgs.writeText "pad-probe.keymap" ''
        #include "${config}/go60.keymap"
        &zephyr_udc0 {
            pad_probe_uart: pad_probe_uart { compatible = "zephyr,cdc-acm-uart"; };
        };
      '';
      conf = pkgs.writeText "pad-probe.conf" ''
        CONFIG_EXPERIMENTAL_RGB_LAYER=y
        CONFIG_USB_DEVICE_STACK=y
        CONFIG_SERIAL=y
        CONFIG_UART_INTERRUPT_DRIVEN=y
        CONFIG_USB_CDC_ACM=y
        CONFIG_ZMK_USB_LOGGING=n
      '';
    in (firmware.zmk.override { board = "go60_${side}"; inherit keymap; kconfig = conf; }).overrideAttrs (old: {
      cmakeFlags = map (builtins.replaceStrings [ (toString upstream) ] [ (toString probe) ]) old.cmakeFlags;
    });
in pkgs.runCommand "go60-pad-probe" {} ''
  mkdir -p $out
  ln -s ${build "lh"} $out/lh
  ln -s ${build "rh"} $out/rh
  cp $out/lh/zmk.uf2 $out/go60-lh-pad-probe.uf2
  cp $out/rh/zmk.uf2 $out/go60-rh-pad-probe.uf2
''
