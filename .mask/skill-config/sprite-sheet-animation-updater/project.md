# AllTheThings / Nib sprite workflow

Read `docs/development/mascot-animation.md` in this consumer for the current cell layout, runtime strips, frame counts, appearance constraints, accessibility rules, and integration contract. Paths in that document are relative to this repository.

Use `tools/validate_allthethings_nib.sh .` for existing asset validation, Swift tests, and the CMake app build. Use `python3 tools/generate_allthethings_operation_rows.py --repo-root . --frames 16` only when regeneration is requested. The shared skill does not own Nib assets or product behavior.
