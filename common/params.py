from openpilot.common.params_pyx import Params, ParamKeyFlag, ParamKeyType, UnknownKeyName
assert Params
assert ParamKeyFlag
assert ParamKeyType
assert UnknownKeyName

if __name__ == "__main__":
  import sys

  params = Params()
  key = sys.argv[1]
  assert params.check_key(key), f"unknown param: {key}"

  if len(sys.argv) == 3:
    val = sys.argv[2]
    print(f"SET: {key} = {val}")
    params.put(key, val)
  elif len(sys.argv) == 2:
    print(f"GET: {key} = {params.get(key)}")

# BEGIN_REMOTE_ACCESS  # SPDX-License-Identifier: MIT (c) 2025 Saeed Almansoori
# Remote Access params
try:
  _params_types  # hint: some trees use PARAMS or _params_types; we guard both
except NameError:
  pass

# Generic registries seen across forks
for _name, _ptype, _default in [
  ("EnableRemoteAccess", "bool", b"0"),
  ("RemoteAccessLoginURL", "bytes", b""),
]:
  try:
    # OpenPilot style
    if 'keys' in globals() and isinstance(keys, dict) and _name not in keys:
      keys[_name] = (_ptype, _default)
  except Exception:
    pass
  try:
    # Alternate registry (_keys or _params_types)
    if '_keys' in globals() and isinstance(_keys, dict) and _name not in _keys:
      _keys[_name] = (_ptype, _default)
  except Exception:
    pass
  try:
    if '_params_types' in globals() and isinstance(_params_types, dict) and _name not in _params_types:
      _params_types[_name] = _ptype
      if '_default_values' in globals() and isinstance(_default_values, dict):
        _default_values[_name] = _default
  except Exception:
    pass
# END_REMOTE_ACCESS
