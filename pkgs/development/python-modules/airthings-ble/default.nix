{ lib
, bleak
, bleak-retry-connector
, buildPythonPackage
, fetchFromGitHub
, poetry-core
, pythonOlder
}:

buildPythonPackage rec {
  pname = "airthings-ble";
  version = "0.5.3";
  format = "pyproject";

  disabled = pythonOlder "3.9";

  src = fetchFromGitHub {
    owner = "vincegio";
    repo = pname;
    rev = "refs/tags/v${version}";
    hash = "sha256-5moJ/Pu1Ixy4s7mCbjxQYROafjHVDM2cmpg0imDznl0=";
  };

  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace 'bleak-retry-connector = "^0.15.1"' 'bleak = "*"'
  '';

  nativeBuildInputs = [
    poetry-core
  ];

  propagatedBuildInputs = [
    bleak
    bleak-retry-connector
  ];

  # Module has no tests
  doCheck = false;

  pythonImportsCheck = [
    "airthings_ble"
  ];

  meta = with lib; {
    description = "Library for Airthings BLE devices";
    homepage = "https://github.com/vincegio/airthings-ble";
    license = with licenses; [ mit ];
    maintainers = with maintainers; [ fab ];
  };
}
