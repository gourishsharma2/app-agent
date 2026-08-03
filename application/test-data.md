# Test Data

## Login Credentials

Test login credentials live in two per-environment files at the project
root, not in `config.properties` (kept to harness settings only):
`test-data/production.properties` and `test-data/staging.properties`. Match
the file to whichever side the login screen's Staging/Production toggle is
set to (see `application/environments.md`); do not mix mobile/password
values across the two files.

Each file holds one or more named credential blocks, flat camelCase keys:
`<name>MobileNumber`, `<name>Password`, optionally `<name>UserCode`. A file
may also define a `default*` block, used automatically when `/run`'s
optional 4th argument (`testUser`) is omitted — neither
`test-data/production.properties` nor `test-data/staging.properties`
currently defines one, so today that 4th argument is effectively required
for both environments (`/run` prompts for it if left out). Any other name
(e.g. `testUserOne`, `testUserTwo`) is selected by passing it as `/run`'s
4th argument, e.g. `/run loginFlow <apk> Production testUserOne`.
