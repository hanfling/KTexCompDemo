//
// BC1-BC5 encoding implementation.
//

//
//  Copyright (c) 2016 Intel Corporation
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this 
//  software and associated documentation files (the "Software"), to deal in the Software 
//  without restriction, including without limitation the rights to use, copy, modify, 
//  merge, publish, distribute, sublicense, and/or sell copies of the Software, and to 
//  permit persons to whom the Software is furnished to do so, subject to the following 
//  conditions: 
//
//  The above copyright notice and this permission notice shall be included in all copies 
//  or substantial portions of the Software.  
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
//  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A 
//  PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT 
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF 
//  CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE 
//  OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#include "kernel_shared.isph"

///////////////////////////////////////////////////////////
//				    BC1/BC2/BC3/BC4/BC5/BC7 shared

///////////////////////////////////////////////////////////
//					 BC1/BC2/BC3/BC4/BC5 encoding

inline int stb__Mul8Bit(int a, int b)
{
	int t = a*b + 128;
	return (t + (t >> 8)) >> 8;
}

inline unsigned int16 stb__As16Bit(int r, int g, int b)
{
	return (stb__Mul8Bit(r,31) << 11) + (stb__Mul8Bit(g,63) << 5) + stb__Mul8Bit(b,31);
}

inline unsigned int16 enc_rgb565(float c[3])
{
	return stb__As16Bit((int)c[0], (int)c[1], (int)c[2]);
}

inline void dec_rgb565(float c[3], int p)
{
	int c2 = (p>>0)&31;
	int c1 = (p>>5)&63;
	int c0 = (p>>11)&31;

	c[0] = (c0<<3)+(c0>>2);
	c[1] = (c1<<2)+(c1>>4);
	c[2] = (c2<<3)+(c2>>2);
}

inline void pick_endpoints_dc(int c0[3], int c1[3], int block[48], int iaxis[3])
{
	for (uniform int p=0; p<3; p++)
		for (uniform int y=0; y<4; y++)
			for (uniform int x=0; x<4; x++)
				c0[p] += block[p*16+y*4+x];

	for (uniform int p=0; p<3; p++)
		c0[p] >>= 4;
}

inline void pick_endpoints(float c0[3], float c1[3], float block[48], float axis[3], float dc[3])
{
	float min_dot = 256*256;
	float max_dot = 0;

	for (uniform int y=0; y<4; y++)
	{
		for (uniform int x=0; x<4; x++)
		{
			float dot = 0;
			for (uniform int p=0; p<3; p++)
				dot += (block[p*16+y*4+x]-dc[p])*axis[p];
	
			min_dot = min(min_dot, dot);
			max_dot = max(max_dot, dot);
		}
	}

	if (max_dot-min_dot < 1f)
	{
		min_dot -= 0.5f;
		max_dot += 0.5f;
	}

	float norm_sq = 0;
	for (uniform int p=0; p<3; p++)
		norm_sq += axis[p]*axis[p];

	float rnorm_sq = rcp(norm_sq);
	for (uniform int p=0; p<3; p++)
	{
		c0[p] = clamp(dc[p]+min_dot*rnorm_sq*axis[p], 0, 255);
		c1[p] = clamp(dc[p]+max_dot*rnorm_sq*axis[p], 0, 255);
	}
}

inline uint32 fast_quant(float block[48], int p0, int p1)
{
	float c0[3];
	float c1[3];
	dec_rgb565(c0, p0);
	dec_rgb565(c1, p1);

	float dir[3];
	for (uniform int p=0; p<3; p++)
		dir[p] = c1[p]-c0[p];
    
	float sq_norm = 0;
	for (uniform int p=0; p<3; p++)
		sq_norm += sq(dir[p]);

	float rsq_norm = rcp(sq_norm);

	for (uniform int p=0; p<3; p++)
		dir[p] *= rsq_norm*3;

	float bias = 0.5;
	for (uniform int p=0; p<3; p++)
		bias -= c0[p]*dir[p];

	uint32 bits = 0;    
	uint32 scaler = 1;
	for (uniform int k=0; k<16; k++)
	{
		float dot = 0;
		for (uniform int p=0; p<3; p++)
			dot += block[k+p*16]*dir[p];

		int q = clamp((int)(dot+bias), 0, 3);

		//bits += q<<(k*2);
		bits += q*scaler;
		scaler *= 4;
	}
	
	return bits;
}

inline void compute_covar_dc(float covar[6], float dc[3], float block[48])
{
	for (uniform int i=0; i<6; i++)
		covar[i] = 0;
	for (uniform int p=0; p<3; p++)
		dc[p] = 0;

	for (uniform int k=0; k<16; k++)
		for (uniform int p=0; p<3; p++)
			dc[p] += block[k+p*16];

	for (uniform int p=0; p<3; p++)
		dc[p] /= 16;
	
	for (uniform int k=0; k<16; k++)
	{
		float rgb[3];
		for (uniform int p=0; p<3; p++)
			rgb[p] = block[k+p*16]-dc[p];
		
		covar[0] += rgb[0]*rgb[0];
		covar[1] += rgb[0]*rgb[1];
		covar[2] += rgb[0]*rgb[2];
		
		covar[3] += rgb[1]*rgb[1];
		covar[4] += rgb[1]*rgb[2];

		covar[5] += rgb[2]*rgb[2];
	}
}

// ugly, but makes BC1 compression 20% faster overall
inline void compute_covar_dc_ugly(float covar[6], float dc[3], float block[48])
{
	for (uniform int p=0; p<3; p++)
	{
		float acc = 0;
		for (uniform int k=0; k<16; k++)
			acc += block[k+p*16];
		dc[p] = acc/16;
	}
	
	float covar0 = 0f;
	float covar1 = 0f;
	float covar2 = 0f;
	float covar3 = 0f;
	float covar4 = 0f;
	float covar5 = 0f;

	for (uniform int k=0; k<16; k++)
	{
		float rgb0, rgb1, rgb2;
		rgb0 = block[k+0*16]-dc[0];
		rgb1 = block[k+1*16]-dc[1];
		rgb2 = block[k+2*16]-dc[2];
		
		covar0 += rgb0*rgb0;
		covar1 += rgb0*rgb1;
		covar2 += rgb0*rgb2;
		
		covar3 += rgb1*rgb1;
		covar4 += rgb1*rgb2;

		covar5 += rgb2*rgb2;
	}

	covar[0] = covar0;
	covar[1] = covar1;
	covar[2] = covar2;
	covar[3] = covar3;
	covar[4] = covar4;
	covar[5] = covar5;
}

inline void bc1_refine(int pe[2], float block[48], unsigned int32 bits, float dc[3])
{
	float c0[3];
	float c1[3];

	if ((bits ^ (bits*4)) < 4)
	{
		// single color
		for (uniform int p=0; p<3; p++)
		{
			c0[p] = dc[p];
			c1[p] = dc[p];
		}
	}
	else
	{
		float Atb1[3] = {0,0,0};
		float sum_q = 0;
		float sum_qq = 0;
		unsigned int32 shifted_bits = bits;
               
		for (uniform int k=0; k<16; k++)
		{
			float q = (int)(shifted_bits&3);
			shifted_bits >>= 2;

			float x = 3-q;
			float y = q;
            
			sum_q += q;
			sum_qq += q*q;

			for (uniform int p=0; p<3; p++)
				Atb1[p] += x*block[k+p*16];
		}
        
		float sum[3];
		float Atb2[3];

		for (uniform int p=0; p<3; p++) 
		{
			sum[p] = dc[p]*16;
			Atb2[p] = 3*sum[p]-Atb1[p];
		}
        
		float Cxx = 16*sq(3)-2*3*sum_q+sum_qq;
		float Cyy = sum_qq;
		float Cxy = 3*sum_q-sum_qq;
		float scale = 3f * rcp(Cxx*Cyy - Cxy*Cxy);

		for (uniform int p=0; p<3; p++)
		{
			c0[p] = (Atb1[p]*Cyy - Atb2[p]*Cxy)*scale;
			c1[p] = (Atb2[p]*Cxx - Atb1[p]*Cxy)*scale;
			
			c0[p] = clamp(c0[p], 0, 255);
			c1[p] = clamp(c1[p], 0, 255);
		}
	}

	pe[0] = enc_rgb565(c0);
	pe[1] = enc_rgb565(c1);
}

inline uint32 fix_qbits(uint32 qbits)
{
	uniform const uint32 mask_01b = 0x55555555;
	uniform const uint32 mask_10b = 0xAAAAAAAA;

	uint32 qbits0 = qbits&mask_01b;
	uint32 qbits1 = qbits&mask_10b;
	qbits = (qbits1>>1) + (qbits1 ^ (qbits0<<1));

	return qbits;
}


///////////////////////////////////////////////////////////
// Low level per block handling
//

inline void CompressBlockBC1_core(float block[48], uint32 data[2])
{
	uniform const int powerIterations = 4;
	uniform const int refineIterations = 1;
    
	float covar[6];
	float dc[3];
	compute_covar_dc_ugly(covar, dc, block);
	
	float eps = 0.001;
	covar[0] += eps;
	covar[3] += eps;
	covar[5] += eps;
	
	float axis[3];
	compute_axis3(axis, covar, powerIterations);
		
	float c0[3];
	float c1[3];
	pick_endpoints(c0, c1, block, axis, dc);
	
	int p[2];
	p[0] = enc_rgb565(c0);
	p[1] = enc_rgb565(c1);
	if (p[0]<p[1])
		swap_ints(&p[0], &p[1], 1);
	
	data[0] = (1<<16)*p[1]+p[0];
	data[1] = fast_quant(block, p[0], p[1]);
    	
	// refine
	for (uniform int i=0; i<refineIterations; i++)
	{
		bc1_refine(p, block, data[1], dc);
		if (p[0]<p[1])
			swap_ints(&p[0], &p[1], 1);
		data[0] = (1<<16)*p[1]+p[0];
		data[1] = fast_quant(block, p[0], p[1]);
	}
	
	data[1] = fix_qbits(data[1]);
}

inline void QuantizeBlockBC2_alpha( float AlphaInput[16], uint32 AlphaOutput[2] )
{
	int32 Rows[4];

	for ( uniform int Row=0; Row<4; Row++ )
	{
		Rows[Row] = ((((int32)round(AlphaInput[4*Row+0]/255.f*15.f))&0xF)<< 0)
							| ((((int32)round(AlphaInput[4*Row+1]/255.f*15.f))&0xF)<< 4)
							| ((((int32)round(AlphaInput[4*Row+2]/255.f*15.f))&0xF)<< 8)
							| ((((int32)round(AlphaInput[4*Row+3]/255.f*15.f))&0xF)<<12);
	}

	AlphaOutput[0] = (Rows[0]<<0) | (Rows[1]<<16);
	AlphaOutput[1] = (Rows[2]<<0) | (Rows[3]<<16);
}

// FIX-ME: Constant color blocks allegedly can cause issues.
inline void CompressBlockBC3_alpha(float block[16], uint32 data[2])
{
	float ep[2] = { 255, 0 };
	
	for (uniform int k=0; k<16; k++)
	{
		ep[0] = min(ep[0], block[k]);
		ep[1] = max(ep[1], block[k]);
	}
    
	if (ep[0] == ep[1])
		ep[1] = ep[0]+0.1f;
	    
	uint32 qblock[2] = { 0, 0 };
	float scale = 7f/(ep[1]-ep[0]);

	for (uniform int k=0; k<16; k++)
	{
		float v = block[k];
		float proj = (v-ep[0])*scale+0.5f;

		int q = clamp((int)proj, 0, 7);

		q = 7-q;

		if (q > 0)
			q++;
		if (q==8)
			q = 1;

		qblock[k/8] |= q << ((k%8)*3);
	}

	// (could be improved by refinement)
	data[0] = clamp((int)ep[0], 0, 255)*256+clamp((int)ep[1], 0, 255);
	data[0] |= qblock[0]<<16;
	data[1] = qblock[0]>>16;
	data[1] |= qblock[1]<<8;
}


///////////////////////////////////////////////////////////
// High level per block handling.
//
// BlockInput[]:
//   0-15: Red
//  16-31: Green
//  32-47: Blue
//  48-63: Alpha
//

inline void CompressBlockBC1( float BlockInput[48], uint32 BlockOutput[2] )
{
	CompressBlockBC1_core( BlockInput, BlockOutput );
}

inline void CompressBlockBC2( float BlockInput[64], uint32 BlockOutput[4] )
{
	QuantizeBlockBC2_alpha( &BlockInput[48], &BlockOutput[0] );
	CompressBlockBC1_core ( &BlockInput[ 0], &BlockOutput[2] );
}

inline void CompressBlockBC3( float BlockInput[64], uint32 BlockOutput[4] )
{
	CompressBlockBC3_alpha( &BlockInput[48], &BlockOutput[0] );
	CompressBlockBC1_core ( &BlockInput[ 0], &BlockOutput[2] );
}

inline void CompressBlockBC4( float BlockInput[16], uint32 BlockOutput[2] )
{
	CompressBlockBC3_alpha( BlockInput, BlockOutput );
}

inline void CompressBlockBC5( float BlockInput[32], uint32 BlockOutput[4] )
{
	CompressBlockBC3_alpha( &BlockInput[ 0], &BlockOutput[0] );
	CompressBlockBC3_alpha( &BlockInput[16], &BlockOutput[2] );
}


///////////////////////////////////////////////////////////
// Dispatcher from input surface to block level.
//
// Templates would be nice here, but not in ispc, maybe preprocessor macros?
// Are there function pointers available in ispc?
// 

// BC1.
inline void LoadCompressStoreBlockBC1_RGBA8( uniform Surface_RGBA8 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[] )
{
	float BlockInput[48];
	uint32 BlockOutput[2];

	LoadUncompressed4x4BlockInterleavedNoAlpha_RGBA8( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockBC1( BlockInput, BlockOutput );
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, 2 );
}
inline void LoadCompressStoreBlockBC1_RGBA16( uniform Surface_RGBA16 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[] )
{
	float BlockInput[48];
	uint32 BlockOutput[2];

	LoadUncompressed4x4BlockInterleavedNoAlpha_RGBA16( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockBC1( BlockInput, BlockOutput);
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, 2 );
}

export void BC1_Compress_RGBA8( uniform Surface_RGBA8 InputSurface[], uniform uint8 OutputBlocks[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockBC1_RGBA8( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks );
}
export void BC1_Compress_RGBA16( uniform Surface_RGBA16 InputSurface[], uniform uint8 OutputBlocks[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockBC1_RGBA16( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks );
}

// BC2.
inline void LoadCompressStoreBlockBC2_RGBA8( uniform Surface_RGBA8 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[] )
{
	float BlockInput[64];
	uint32 BlockOutput[4];

	LoadUncompressed4x4BlockInterleaved_RGBA8( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockBC2( BlockInput, BlockOutput );
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, 4 );
}
inline void LoadCompressStoreBlockBC2_RGBA16( uniform Surface_RGBA16 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[] )
{
	float BlockInput[64];
	uint32 BlockOutput[4];

	LoadUncompressed4x4BlockInterleaved_RGBA16( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockBC2( BlockInput, BlockOutput);
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, 4 );
}

export void BC2_Compress_RGBA8( uniform Surface_RGBA8 InputSurface[], uniform uint8 OutputBlocks[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockBC2_RGBA8( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks );
}
export void BC2_Compress_RGBA16( uniform Surface_RGBA16 InputSurface[], uniform uint8 OutputBlocks[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockBC2_RGBA16( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks );
}

// BC3.
inline void LoadCompressStoreBlockBC3_RGBA8( uniform Surface_RGBA8 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[] )
{
	float BlockInput[64];
	uint32 BlockOutput[4];

	LoadUncompressed4x4BlockInterleaved_RGBA8( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockBC3( BlockInput, BlockOutput );
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, 4 );
}
inline void LoadCompressStoreBlockBC3_RGBA16( uniform Surface_RGBA16 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[] )
{
	float BlockInput[64];
	uint32 BlockOutput[4];

	LoadUncompressed4x4BlockInterleaved_RGBA16( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockBC3( BlockInput, BlockOutput);
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, 4 );
}

export void BC3_Compress_RGBA8( uniform Surface_RGBA8 InputSurface[], uniform uint8 OutputBlocks[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockBC3_RGBA8( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks );
}
export void BC3_Compress_RGBA16( uniform Surface_RGBA16 InputSurface[], uniform uint8 OutputBlocks[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockBC3_RGBA16( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks );
}

// BC4.
inline void LoadCompressStoreBlockBC4_R8( uniform Surface_R8 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[] )
{
	float BlockInput[16];
	uint32 BlockOutput[2];

	LoadUncompressed4x4Block_R8( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockBC4( BlockInput, BlockOutput );
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, 2 );
}
inline void LoadCompressStoreBlockBC4_R16( uniform Surface_R16 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[] )
{
	float BlockInput[16];
	uint32 BlockOutput[2];

	LoadUncompressed4x4Block_R16( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockBC4( BlockInput, BlockOutput );
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, 2 );
}

export void BC4_Compress_R8( uniform Surface_R8 InputSurface[], uniform uint8 OutputBlocks[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockBC4_R8( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks );
}
export void BC4_Compress_R16( uniform Surface_R16 InputSurface[], uniform uint8 OutputBlocks[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockBC4_R16( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks );
}

// BC5.
inline void LoadCompressStoreBlockBC5_RG8( uniform Surface_RG8 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[] )
{
	float BlockInput[32];
	uint32 BlockOutput[2];

	LoadUncompressed4x4BlockInterleaved_RG8( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockBC5( BlockInput, BlockOutput );
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, 4 );
}
inline void LoadCompressStoreBlockBC5_RG16( uniform Surface_RG16 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[] )
{
	float BlockInput[32];
	uint32 BlockOutput[2];

	LoadUncompressed4x4BlockInterleaved_RG16( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockBC5( BlockInput, BlockOutput );
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, 4 );
}

export void BC5_Compress_RG8( uniform Surface_RG8 InputSurface[], uniform uint8 OutputBlocks[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockBC5_RG8( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks );
}
export void BC5_Compress_RG16( uniform Surface_RG16 InputSurface[], uniform uint8 OutputBlocks[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockBC5_RG16( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks );
}
