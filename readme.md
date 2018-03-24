# Fast ISPC Texture Compressor

Texture compression for BC1/BC3/BC6H/BC7, ETC1 and ASTC.

Uses [ISPC compiler](https://ispc.github.io/).

See [Fast ISPC Texture Compressor](https://software.intel.com/en-us/articles/fast-ispc-texture-compressor-update) post on
Intel Developer Zone and the included [Technical Paper](./ISPC%20Texture%20Compressor/ISPC%20Texture%20Compressor.pdf).

## Supported compression formats

* BC1
* BC3
* BC6H
* BC7
* ETC1
* ASTC

## Limitations

* Lack of notion about user intended colorspaces or compression metrics (sRGB is assumed for LDR input).
* Half floating point input for BC6H and otherwise unsigned byte input only.
* Very basic support for BC3 alpha channel.
* BC1 lacks punchthrough alpha support.
* ASTC is LDR only and won't support block sizes above 8x8.
* No decompression support.
* No unit testing.

## License

ISPC Texture Compressor is distributed under the MIT License, which is also known under the name X11 License. The full License is included inside license.txt.

## Build Instructions

* Windows:
	* Use Visual Studio 2012 on later, build solution or project files.
	* ISPC version 1.8.2 is included in this repo.

* Mac OS X:
	* Xcode project file included only for compressor itself, not for the examples.
	* You'll need to get ISPC compiler version [1.8.2 build](https://sf.net/projects/ispcmirror) and put the compiler executable into `ISPC Texture Compressor/ispc_osx`.
	* Use `ISPC Texture Compressor/ispc_texcomp.xcodeproj`, tested with Xcode 7.3.
	* Minimum OS X deployment version set to 10.9.
	* dylib install name is set to `@executable_path/../Frameworks/$(EXECUTABLE_PATH)`

* Linux:
	* Makefile included only for compressor itself, not for the examples.
	* You'll need to get ISPC compiler version [1.8.2 build](https://sf.net/projects/ispcmirror) and put the compiler executable into `ISPC Texture Compressor/ispc_linux`.
	* `make -f Makefile.linux` from `ISPC Texture Compressor` folder.
