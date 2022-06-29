{ lib, stdenv
, makeWrapper, python
, runCommand, wrapBintoolsWith, wrapCCWith, autoPatchelfHook
, buildAndroidndk, androidndk, targetAndroidndkPkgs
}:

let
  # Mapping from a platform to information needed to unpack NDK stuff for that
  # platform.
  #
  # N.B. The Android NDK uses slightly different LLVM-style platform triples
  # than we do. We don't just use theirs because ours are less ambiguous and
  # some builds need that clarity.
  #
  # FIXME:
  # There's some dragons here. Build host and target concepts are being mixed up.
  ndkInfoFun = { config, ... }: {
    x86_64-apple-darwin = {
      double = "darwin-x86_64";
    };
    x86_64-unknown-linux-gnu = {
      double = "linux-x86_64";
    };
    i686-unknown-linux-android = {
      triple = "i686-linux-android";
      arch = "x86";
      # LEGACY
      toolchain = "x86";
      gccVer = "4.9";
    };
    x86_64-unknown-linux-android = {
      triple = "x86_64-linux-android";
      arch = "x86_64";
      # LEGACY
      toolchain = "x86_64";
      gccVer = "4.9";
    };
    armv7a-unknown-linux-androideabi = {
      arch = "arm";
      triple = "arm-linux-androideabi";
      # LEGACY
      toolchain = "arm-linux-androideabi";
      gccVer = "4.9";
    };
    aarch64-unknown-linux-android = {
      arch = "arm64";
      triple = "aarch64-linux-android";
      # LEGACY
      toolchain = "aarch64-linux-android";
      gccVer = "4.9";
    };
  }.${config} or
    (throw "Android NDK doesn't support ${config}, as far as we know");

  buildInfo = ndkInfoFun stdenv.buildPlatform;
  hostInfo = ndkInfoFun stdenv.hostPlatform;
  targetInfo = ndkInfoFun stdenv.targetPlatform;

  inherit (stdenv.targetPlatform) sdkVer;
  suffixSalt = lib.replaceStrings ["-" "."] ["_" "_"] stdenv.targetPlatform.config;

  # targetInfo.triple is what Google thinks the toolchain should be, this is a little
  # different from what we use. We make it four parts to conform with the existing
  # standard more properly.
  targetConfig = lib.optionalString (stdenv.targetPlatform != stdenv.hostPlatform) (stdenv.targetPlatform.config);
in

rec {
  # Misc tools
  binaries = stdenv.mkDerivation {
    pname = "${targetConfig}-ndk-toolchain";
    inherit (androidndk) version;
    nativeBuildInputs = [ makeWrapper python autoPatchelfHook ];
    propagatedBuildInputs = [ androidndk ];
    passthru = {
      isClang = true; # clang based cc, but bintools ld
    };
    dontUnpack = true;
    dontBuild = true;
    dontStrip = true;
    dontConfigure = true;
    dontPatch = true;
    autoPatchelfIgnoreMissingDeps = true;
    installPhase = ''
      if [ ! -d ${androidndk}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/${buildInfo.double} ]; then
        # LEGACY: make-standalone-toolchain is deprecated
        #         https://developer.android.com/ndk/guides/standalone_toolchain
        ${androidndk}/libexec/android-sdk/ndk-bundle/build/tools/make-standalone-toolchain.sh --arch=${targetInfo.arch} --install-dir=$out/toolchain --platform=${sdkVer} --force
      else
        # https://developer.android.com/ndk/guides/other_build_systems
        mkdir -p $out
        cp -r ${androidndk}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/${buildInfo.double} $out/toolchain
        find $out/toolchain -type d -exec chmod 777 {} \;
      fi

      if [ ! -d $out/toolchain/sysroot/usr/lib/${targetInfo.triple}/${sdkVer} ]; then
        echo "NDK does not contain libraries for SDK version ${sdkVer}";
        exit 1
      fi

      ln -vfs $out/toolchain/sysroot/usr/lib $out/lib
      ln -s $out/toolchain/sysroot/usr/lib/${targetInfo.triple}/*.so $out/lib/
      ln -s $out/toolchain/sysroot/usr/lib/${targetInfo.triple}/*.a $out/lib/
      chmod +w $out/lib/*
      ln -s $out/toolchain/sysroot/usr/lib/${targetInfo.triple}/${sdkVer}/*.so $out/lib/
      ln -s $out/toolchain/sysroot/usr/lib/${targetInfo.triple}/${sdkVer}/*.o $out/lib/

      echo "INPUT(-lc++_static)" > $out/lib/libc++.a

      ln -s $out/toolchain/bin $out/bin
      ln -s $out/toolchain/${targetInfo.triple}/bin/* $out/bin/
      for f in $out/bin/${targetInfo.triple}-*; do
        ln -s $f ''${f/${targetInfo.triple}-/${targetConfig}-}
      done
      for f in $(find $out/toolchain -type d -name ${targetInfo.triple}); do
        ln -s $f ''${f/${targetInfo.triple}/${targetConfig}}
      done

      # LEGACY: get rid of gcc and g++, otherwise wrapCCWith will use them instead of clang
      rm -f $out/bin/${targetConfig}-gcc $out/bin/${targetConfig}-g++

      # LEGACY: ld doesn't properly include transitive library dependencies.
      #         Let's use gold instead
      rm -f $out/bin/${targetConfig}-ld
      if [[ -f  $out/bin/${targetConfig}-ld.gold ]]; then
        ln -s $out/bin/${targetConfig}-ld.gold $out/bin/${targetConfig}-ld
      else
        ln -s $out/bin/lld $out/bin/${targetConfig}-ld
      fi

      (cd $out/bin;
        for tool in llvm-*; do
          ln -sf $tool ${targetConfig}-$(echo $tool | sed 's/llvm-//')
          ln -sf $tool $(echo $tool | sed 's/llvm-//')
        done)

      # handle last, as llvm-as is for llvm bytecode
      ln -sf $out/bin/${targetInfo.triple}-as $out/bin/${targetConfig}-as
      ln -sf $out/bin/${targetInfo.triple}-as $out/bin/as

      patchShebangs $out/bin
    '';
  };

  binutils = wrapBintoolsWith {
    bintools = binaries;
    libc = targetAndroidndkPkgs.libraries;
  };

  clang = wrapCCWith {
    cc = binaries // {
      # for packages expecting libcompiler-rt, etc. to come from here (stdenv.cc.cc.lib)
      lib = targetAndroidndkPkgs.libraries;
    };
    bintools = binutils;
    libc = targetAndroidndkPkgs.libraries;
    extraBuildCommands = ''
      echo "-D__ANDROID_API__=${stdenv.targetPlatform.sdkVer}" >> $out/nix-support/cc-cflags
      if [ ! -d ${androidndk}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/${hostInfo.double} ]; then
        # LEGACY: probably won't work for any recent android
        echo "--gcc-toolchain=${androidndk}/libexec/android-sdk/ndk-bundle/toolchains/${targetInfo.toolchain}-${targetInfo.gccVer}/prebuilt/${hostInfo.double}" >> $out/nix-support/cc-cflags
        echo "-fuse-ld=$out/bin/${targetConfig}-ld.gold -L${binaries}/lib" >> $out/nix-support/cc-ldflags
      else
        # Android needs executables linked with -pie since version 5.0
        # Use -fPIC for compilation, and link with -pie if no -shared flag used in ldflags
        echo "-target ${targetInfo.triple} -fPIC" >> $out/nix-support/cc-cflags
        echo "-z,noexecstack -z,relro -z,now" >> $out/nix-support/cc-ldflags
        echo 'if [[ ! " $@ " =~ " -shared " ]]; then NIX_LDFLAGS_${suffixSalt}+=" -pie"; fi' >> $out/nix-support/add-flags.sh
        echo "-Xclang -mnoexecstack" >> $out/nix-support/cc-cxxflags
      fi
      if [ ${targetInfo.triple} == arm-linux-androideabi ]; then
        # https://android.googlesource.com/platform/external/android-cmake/+/refs/heads/cmake-master-dev/android.toolchain.cmake
        echo "--fix-cortex-a8" >> $out/nix-support/cc-ldflags
      fi
    '';
  };

  # Bionic lib C and other libraries.
  #
  # We use androidndk from the previous stage, else we waste time or get cycles
  # cross-compiling packages to wrap incorrectly wrap binaries we don't include
  # anyways.
  libraries = runCommand "bionic-prebuilt" {} ''
    if [ -d ${buildAndroidndk}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt ]; then
      lpath=${buildAndroidndk}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/${buildInfo.double}/sysroot/usr/lib/${targetInfo.triple}/${sdkVer}
    else
      # LEGACY
      lpath=${buildAndroidndk}/libexec/android-sdk/ndk-bundle/platforms/android-${sdkVer}/arch-${hostInfo.arch}/usr/${if hostInfo.arch == "x86_64" then "lib64" else "lib"}
    fi
    if [ ! -d $lpath ]; then
      echo "NDK does not contain libraries for SDK version ${sdkVer} <$lpath>"
      exit 1
    fi
    mkdir -p $out/lib
    cp $lpath/*.so $lpath/*.a $out/lib
    chmod +w $out/lib/*
    cp $lpath/* $out/lib
  '';
}
