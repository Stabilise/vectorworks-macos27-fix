# Third-Party Notices

## iODBC

`vendor/libiodbc-3.52.16.tar.gz` is the unmodified iODBC 3.52.16 source release published by OpenLink Software at <https://github.com/openlink/iODBC/releases/tag/v3.52.16>.

iODBC is Copyright (C) 1995 Ke Jin and Copyright (C) 1996-2023 OpenLink Software. It is made available under your choice of the GNU Library General Public License (LGPL) version 2 or the BSD licence; the full text of both is included inside the source release (`LICENSE`, `LICENSE.LGPL` and `LICENSE.BSD`). This project uses it under the BSD licence.

`vectorworks-iodbc-fix.sh` compiles this source, unchanged, into `libiodbc.2.dylib` and places that library inside the Vectorworks Support plug-in on the Mac where the script runs. No compiled copy of iODBC is distributed in this repository.

## Acknowledgements

The cause of the Vectorworks launch failure on macOS 27 was identified by Wagner R. Ponce (ANIFONIX), who published the first workaround at <https://github.com/wkrodrig/vectorworks-2025-2026-wont-launch-macos27-fix> under the MIT Licence. Mike Hayes reported the in-plug-in library approach in that project's issue 2. No code from that project is used here.
