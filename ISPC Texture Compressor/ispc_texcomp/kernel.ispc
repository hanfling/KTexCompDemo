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

inline void QuantizeBlockBC2_alpha(float block[16], uint32 data[2])
{
	uint64 out = 0;

	// Integer values 0-15 can be exactly represented in IEEE 754.
	for (uniform int k=0; k<16; k++)
		out |= (((uint64)round(block[k]/255.f*15.f))&0xFull)<<(k*4); // Performance warning, but ispc documentation won't show which rules it follows for shifting signed numbers.

	data[0] = (out    )&0xFFFFFFFFull;
	data[1] = (out>>32)&0xFFFFFFFFull;
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

inline void CompressBlockBC1(uniform rgba_surface src[], int xx, uniform int yy, uniform uint8 dst[])
{
	float block[48];
	uint32 data[2];

	load_4x4_block_interleaved(block, src, xx, yy);
	
	CompressBlockBC1_core(block, data);

	store_data(dst, src->width, xx, yy, data, 2);
}

inline void CompressBlockBC2(uniform rgba_surface src[], int xx, uniform int yy, uniform uint8 dst[])
{
	float block[64];
	uint32 data[4];

	load_4x4_block_interleaved_rgba(block, src, xx, yy);
	
	QuantizeBlockBC2_alpha(&block[48], &data[0]);
	CompressBlockBC1_core(block, &data[2]);

	store_data(dst, src->width, xx, yy, data, 4);
}

inline void CompressBlockBC3(uniform rgba_surface src[], int xx, uniform int yy, uniform uint8 dst[])
{
	float block[64];
	uint32 data[4];

	load_4x4_block_interleaved_rgba(block, src, xx, yy);
	
	CompressBlockBC3_alpha(&block[48], &data[0]);
	CompressBlockBC1_core(block, &data[2]);

	store_data(dst, src->width, xx, yy, data, 4);
}

inline void CompressBlockBC4(uniform red_surface src[], int xx, uniform int yy, uniform uint8 dst[])
{
	float block[16];
	uint32 data[2];

	load_4x4_block_red(block, src, xx, yy);
	
	CompressBlockBC3_alpha(&block[0], &data[0]);

	store_data(dst, src->width, xx, yy, data, 2);
}

inline void CompressBlockBC5(uniform rg_surface src[], int xx, uniform int yy, uniform uint8 dst[])
{
	float block[32];
	uint32 data[4];

	load_4x4_block_interleaved_rg(block, src, xx, yy);
	
	CompressBlockBC3_alpha(&block[0], &data[0]);
	CompressBlockBC3_alpha(&block[16], &data[2]);

	store_data(dst, src->width, xx, yy, data, 4);
}

export void CompressBlocksBC1_ispc(uniform rgba_surface src[], uniform uint8 dst[])
{	
	for (uniform int yy = 0; yy<src->height/4; yy++)
		foreach (xx = 0 ... src->width/4)
			CompressBlockBC1(src, xx, yy, dst);
}

export void CompressBlocksBC2_ispc(uniform rgba_surface src[], uniform uint8 dst[])
{	
	for (uniform int yy = 0; yy<src->height/4; yy++)
		foreach (xx = 0 ... src->width/4)
			CompressBlockBC2(src, xx, yy, dst);
}

export void CompressBlocksBC3_ispc(uniform rgba_surface src[], uniform uint8 dst[])
{	
	for (uniform int yy = 0; yy<src->height/4; yy++)
		foreach (xx = 0 ... src->width/4)
			CompressBlockBC3(src, xx, yy, dst);
}

export void CompressBlocksBC4_ispc(uniform red_surface src[], uniform uint8 dst[])
{	
	for (uniform int yy = 0; yy<src->height/4; yy++)
		foreach (xx = 0 ... src->width/4)
			CompressBlockBC4(src, xx, yy, dst);
}

export void CompressBlocksBC5_ispc(uniform rg_surface src[], uniform uint8 dst[])
{	
	for (uniform int yy = 0; yy<src->height/4; yy++)
		foreach (xx = 0 ... src->width/4)
			CompressBlockBC5(src, xx, yy, dst);
}
