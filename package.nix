{
  lib,
  stdenv,
  fetchurl,
  runCommand,
  sequoia-sqv,
  buildPackages,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  dpkg,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  adwaita-icon-theme,
  gsettings-desktop-schemas,
  gtk3,
  gtk4,
  qt6,
  libx11,
  libxscrnsaver,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxrandr,
  libxrender,
  libxtst,
  libdrm,
  libkrb5,
  libuuid,
  libxkbcommon,
  libxshmfence,
  libgbm,
  nspr,
  nss,
  pango,
  pciutils,
  pipewire,
  snappy,
  speechd-minimal,
  udev,
  wayland,
  xdg-utils,
  coreutils,
  libxcb,
  vulkan-loader,
  zlib,
  # command line arguments which are always set e.g "--disable-gpu"
  commandLineArgs ? "",
  # Necessary for USB audio devices.
  pulseSupport ? true,
  libpulseaudio,
  # For GPU acceleration support on Wayland (without the lib it doesn't seem to work)
  libGL,
  # For video acceleration via VA-API (--enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder)
  libvaSupport ? true,
  libva,
  enableVideoAcceleration ? libvaSupport,
  # For Vulkan support (--enable-features=Vulkan); disabled by default as it seems to break VA-API
  vulkanSupport ? false,
  enableVulkan ? vulkanSupport,
}:

let
  # The checksum file Brave signs is the only source of the version and the
  # hash, so a valid signature over it authenticates both. update.py parses
  # it with the same pattern.
  checksumFile = ./sources/brave-browser_amd64.deb.sha256;
  checksum = builtins.match "([0-9a-f]{64})  (brave-browser_([0-9]+(\\.[0-9]+)*)_amd64\\.deb)\n?" (
    builtins.readFile checksumFile
  );
  sha256 =
    assert lib.assertMsg (checksum != null) "unexpected format in ${toString checksumFile}";
    builtins.elemAt checksum 0;
  debName = builtins.elemAt checksum 1;
  version = builtins.elemAt checksum 2;

  unverifiedDeb = fetchurl {
    name = debName;
    urls = [
      "https://github.com/brave/brave-browser/releases/download/v${version}/${debName}"
      "https://brave-browser-apt-release.s3.brave.com/pool/main/b/brave-browser/${debName}"
    ];
    inherit sha256;
  };

  # The .deb carries no signature of its own; nothing unpacks it until the
  # signed checksum it was fetched by has been verified.
  verifiedDeb =
    runCommand debName
      {
        nativeBuildInputs = [ sequoia-sqv ];
      }
      ''
        sqv --keyring ${./keys/checksums-release.asc} \
          ${./sources/brave-browser_amd64.deb.sha256.asc} ${checksumFile}
        ln -s ${unverifiedDeb} $out
      '';

  deps = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    gtk4
    libdrm
    libx11
    libGL
    libxkbcommon
    libxscrnsaver
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxshmfence
    libxtst
    libuuid
    libgbm
    nspr
    nss
    pango
    pciutils # ANGLE dlopens libpci to identify GPUs, including for VA-API device selection.
    pipewire
    udev
    wayland
    libxcb
    zlib
    snappy
    speechd-minimal # Text-to-speech through speech-dispatcher (--enable-speech-dispatcher).
    libkrb5
    vulkan-loader # Chromium and Dawn dlopen libvulkan.so.1 by name.
    qt6.qtbase
  ]
  ++ lib.optional pulseSupport libpulseaudio
  ++ lib.optional libvaSupport libva;

  rpath = lib.makeLibraryPath deps + ":" + lib.makeSearchPathOutput "lib" "lib64" deps;
  binpath = lib.makeBinPath deps;

  enableFeatures =
    lib.optionals enableVideoAcceleration [
      "AcceleratedVideoDecodeLinuxGL"
      "AcceleratedVideoEncoder"
    ]
    ++ lib.optional enableVulkan "Vulkan";

  disableFeatures = [
    "OutdatedBuildDetector"
  ] # disable automatic updates
  # The feature disable is needed for VAAPI to work correctly: https://github.com/brave/brave-browser/issues/20935
  ++ lib.optionals enableVideoAcceleration [ "UseChromeOSDirectVideoDecoder" ];

  optDir = "opt/brave.com/brave";
in
stdenv.mkDerivation {
  pname = "brave";
  inherit version;

  __structuredAttrs = true;
  strictDeps = true;

  src = verifiedDeb;

  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true;
  doInstallCheck = true;

  nativeBuildInputs = [
    dpkg
    # override doesn't preserve splicing https://github.com/NixOS/nixpkgs/issues/132651
    # Has to use `makeShellWrapper` from `buildPackages` even though `makeShellWrapper` from the inputs is spliced because `propagatedBuildInputs` would pick the wrong one because of a different offset.
    (buildPackages.wrapGAppsHook3.override { makeWrapper = buildPackages.makeShellWrapper; })
  ];

  buildInputs = [
    # needed for GSETTINGS_SCHEMAS_PATH
    glib
    gsettings-desktop-schemas
    gtk3
    gtk4

    # needed for XDG_ICON_DIRS
    adwaita-icon-theme
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out $out/bin

    cp -R usr/share $out
    cp -R opt/ $out/opt

    export BINARYWRAPPER=$out/${optDir}/brave-browser

    # Fix path to bash in $BINARYWRAPPER
    substituteInPlace $BINARYWRAPPER \
        --replace-fail /bin/bash ${stdenv.shell} \
        --replace-fail 'CHROME_WRAPPER' 'WRAPPER'

    ln -sf $BINARYWRAPPER $out/bin/brave

    for exe in $out/${optDir}/{brave,chrome_crashpad_handler}; do
        patchelf \
            --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
            --set-rpath "${rpath}" $exe
    done

    # Fix paths
    substituteInPlace $out/share/applications/{brave-browser,com.brave.Browser}.desktop \
        --replace-fail /usr/bin/brave-browser-stable $out/bin/brave
    substituteInPlace $out/share/gnome-control-center/default-apps/brave-browser.xml \
        --replace-fail /opt/brave.com $out/opt/brave.com
    substituteInPlace $out/${optDir}/default-app-block \
        --replace-fail /opt/brave.com $out/opt/brave.com

    # Correct icons location
    icon_sizes=("16" "24" "32" "48" "64" "128" "256")

    for icon in ''${icon_sizes[*]}
    do
        mkdir -p $out/share/icons/hicolor/''${icon}x''${icon}/apps
        ln -s $out/${optDir}/product_logo_''${icon}.png $out/share/icons/hicolor/''${icon}x''${icon}/apps/brave-browser.png
    done

    # ANGLE loads this copy by absolute path; the NixOS-patched loader finds ICDs
    # under /run/opengl-driver, the bundled one does not.
    rm $out/${optDir}/libvulkan.so.1
    ln -s ${lib.getLib vulkan-loader}/lib/libvulkan.so.1 $out/${optDir}/libvulkan.so.1

    # Replace xdg-settings and xdg-mime
    ln -sf ${xdg-utils}/bin/xdg-settings $out/${optDir}/xdg-settings
    ln -sf ${xdg-utils}/bin/xdg-mime $out/${optDir}/xdg-mime

    runHook postInstall
  '';

  preFixup = ''
    # Add command line args to wrapGApp.
    gappsWrapperArgs+=(
      --prefix LD_LIBRARY_PATH : ${rpath}
      --prefix PATH : ${binpath}
      --suffix PATH : ${
        lib.makeBinPath [
          xdg-utils
          coreutils
        ]
      }
      --set CHROME_WRAPPER brave
      ${lib.optionalString (enableFeatures != [ ]) ''
        --add-flags "--enable-features=${lib.concatStringsSep "," enableFeatures}\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+,WaylandWindowDecorations --enable-wayland-ime=true}}"
      ''}
      ${lib.optionalString (disableFeatures != [ ]) ''
        --add-flags "--disable-features=${lib.concatStringsSep "," disableFeatures}"
      ''}
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto}}"
      --add-flags ${lib.escapeShellArg commandLineArgs}
    )
  '';

  installCheckPhase = ''
    # Bypass upstream wrapper which suppresses errors
    $out/${optDir}/brave --version
  '';

  meta = {
    homepage = "https://brave.com/";
    description = "Privacy-oriented browser for Desktop and Laptop computers";
    changelog =
      "https://github.com/brave/brave-browser/blob/master/CHANGELOG_DESKTOP.md#"
      + lib.replaceStrings [ "." ] [ "" ] version;
    longDescription = ''
      Brave browser blocks the ads and trackers that slow you down,
      chew up your bandwidth, and invade your privacy. Brave lets you
      contribute to your favorite creators automatically.
    '';
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    license = lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "brave";
  };
}
