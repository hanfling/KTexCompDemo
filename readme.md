# Fast ISPC Texture Compressor

Texture compression for BC1-BC7, ETC1 and ASTC.

Uses [ISPC compiler](https://ispc.github.io/).

See [Fast ISPC Texture Compressor](https://software.intel.com/en-us/articles/fast-ispc-texture-compressor-update) post on
Intel Developer Zone and the included [Technical Paper](./ISPC%20Texture%20Compressor/ISPC%20Texture%20Compressor.pdf).

## Supported compression formats

* [BC1](https://www.khronos.org/registry/OpenGL/extensions/EXT/EXT_texture_compression_s3tc.txt)
* [BC2](https://www.khronos.org/registry/OpenGL/extensions/EXT/EXT_texture_compression_s3tc.txt)
* [BC3](https://www.khronos.org/registry/OpenGL/extensions/EXT/EXT_texture_compression_s3tc.txt)
* [BC4](https://www.khronos.org/registry/OpenGL/extensions/ARB/ARB_texture_compression_rgtc.txt)
* [BC5](https://www.khronos.org/registry/OpenGL/extensions/ARB/ARB_texture_compression_rgtc.txt)
* [BC6H](https://www.khronos.org/registry/OpenGL/extensions/ARB/ARB_texture_compression_bptc.txt)
* [BC7](https://www.khronos.org/registry/OpenGL/extensions/ARB/ARB_texture_compression_bptc.txt)
* [ETC1](https://www.khronos.org/registry/OpenGL/extensions/OES/OES_compressed_ETC1_RGB8_texture.txt)
* [ASTC](https://www.khronos.org/registry/OpenGL/extensions/KHR/KHR_texture_compression_astc_hdr.txt)

## Strenghts
* Compression speed runtime adjustable over two magnitudes, making this library suitable for fast iteration and production use.
* [BC7 texture compression.](http://gamma.cs.unc.edu/FasTC/)
* Visual demonstration tools included.

## Limitations

* Lack of notion about user intended colorspaces or compression metrics (sRGB is assumed for LDR input).
* Half floating point input for BC6H and otherwise unsigned byte input only.
* Very basic support for BC3 alpha channel and BC4/BC5.
* BC1 lacks punchthrough alpha support.
* Only unsigned format of BC4/BC5/BC6H is supported.
* ASTC is LDR only and won't support block sizes above 8x8.
* Lack of documentation.
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
