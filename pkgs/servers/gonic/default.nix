{ lib, buildGoModule, fetchFromGitHub
, pkg-config, taglib, alsa-lib
, zlib

# Disable on-the-fly transcoding,
# removing the dependency on ffmpeg.
# The server will (as of 0.11.0) gracefully fall back
# to the original file, but if transcoding is configured
# that takes a while. So best to disable all transcoding
# in the configuration if you disable transcodingSupport.
, transcodingSupport ? true, ffmpeg }:

buildGoModule rec {
  pname = "gonic";
  version = "0.13.1";
  src = fetchFromGitHub {
    owner = "sentriz";
    repo = pname;
    rev = "v${version}";
    sha256 = "08zr5cbmn25wfi1sjfsb311ycn1855x57ypyn5165zcz49pcfzxn";
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ taglib alsa-lib zlib ];
  vendorSha256 = "0inxlqxnkglz4j14jav8080718a80nqdcl866lkql8r6zcxb4fm9";

  # TODO(Profpatsch): write a test for transcoding support,
  # since it is prone to break
  postPatch = lib.optionalString transcodingSupport ''
    substituteInPlace \
      server/encode/encode.go \
      --replace \
        '"ffmpeg"' \
        '"${lib.getBin ffmpeg}/bin/ffmpeg"'
  '';

  meta = {
    homepage = "https://github.com/sentriz/gonic";
    description = "Music streaming server / subsonic server API implementation";
    license = lib.licenses.gpl3Plus;
    maintainers = with lib.maintainers; [ Profpatsch ];
  };
}
