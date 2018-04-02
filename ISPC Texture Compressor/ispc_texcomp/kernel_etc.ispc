//
// ETC1 encoding implementation.
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
//					 ETC encoding

struct etc_enc_settings
{
	int fastSkipTreshold;
};

struct etc_enc_state
{
	float block[64];
	int prev_qcenter[3];

	float best_err;
	uint32 best_data[2];

	uniform bool diff;

	// settings
	uniform int fastSkipTreshold;
};

inline uniform int get_etc1_dY(uniform int table, uniform int q)
{
	static uniform const int etc_codeword_table[8][4] =
	{
		{ -8, -2, 2, 8 },
		{ -17, -5, 5, 17 },
		{ -29, -9, 9, 29 },
		{ -42, -13, 13, 42 },
		{ -60, -18, 18, 60 },
		{ -80, -24, 24, 80 },
		{ -106, -33, 33, 106 },
		{ -183, -47, 47, 183 },
	};

	return etc_codeword_table[table][q];
}

uniform int remap_q[] = { 2, 3, 1, 0 };

int get_remap2_q(int x)
{
	x -= 2;
	if (x < 0)
		x = 1 - x;
	return x;
}

int extend_4to8bits(int value)
{
	return (value << 4) | value;
}

int extend_5to8bits(int value)
{
	return (value << 3) | (value >> 2);
}

int quantize_4bits(float value)
{
	return clamp((value / 255.0f) * 15 + 0.5, 0, 15);
}

int quantize_5bits(float value)
{
	return clamp((value / 255.0f) * 31 + 0.5, 0, 31);
}

void center_quant_dequant(int qcenter[3], float center[3], uniform bool diff, int prev_qcenter[3])
{
	if (diff)
	{
		for (uniform int p = 0; p < 3; p++)
		{
			qcenter[p] = quantize_5bits(center[p]);

			if (prev_qcenter[0] >= 0)
			{
				if (qcenter[p] - prev_qcenter[p] > 3)
					qcenter[p] = prev_qcenter[p] + 3;
				if (qcenter[p] - prev_qcenter[p] < -4)
					qcenter[p] = prev_qcenter[p] - 4;
			}

			center[p] = extend_5to8bits(qcenter[p]);
		}
	}
	else
	{
		for (uniform int p = 0; p < 3; p++)
		{
			qcenter[p] = quantize_4bits(center[p]);
			center[p] = extend_4to8bits(qcenter[p]);
		}
	}
}

float quantize_pixels_etc1_half(uint32 qblock[1], float block[48], float center[3], uniform int table)
{
	float total_err = 0;
	uint32 bits = 0;

	for (uniform int y = 0; y < 2; y++)
	{
		for (uniform int x = 0; x < 4; x++)
		{
			float best_err = sq(255) * 3;
			int best_q = -1;

			for (uniform int q = 0; q < 4; q++)
			{
				int dY = get_etc1_dY(table, remap_q[q]);

				float err = 0;
				for (int p = 0; p < 3; p++)
					err += sq(block[16 * p + y*4+x] - clamp(center[p] + dY, 0, 255));

				if (err < best_err)
				{
					best_err = err;
					best_q = q;
				}
			}

			assert(best_q >= 0);

			bits |= (best_q  & 1) << (x * 4 + y);
			bits |= (best_q >> 1) << (x * 4 + y + 16);
			total_err += best_err;
		}
	}

	qblock[0] = bits;
	return total_err;
}

float compress_etc1_half_1(uint32 out_qbits[1], int out_table[1], int out_qcenter[3], float half_pixels[], uniform bool diff, int prev_qcenter[3])
{
	float dc[3];

	for (uniform int p = 0; p<3; p++)
		dc[p] = 0;

	for (uniform int k = 0; k<8; k++)
		for (uniform int p = 0; p<3; p++)
			dc[p] += half_pixels[k + p * 16];

	float best_error = sq(255) * 3 * 8.0f;
	int best_table = -1;
	int best_qcenter[3];
	uint32 best_qbits;

	for (uniform int table_level = 0; table_level < 8; table_level++)
	{
		float center[3];
		int qcenter[3];
		uint32 qbits;

		for (uniform int p = 0; p < 3; p++)
			center[p] = dc[p] / 8 - get_etc1_dY(table_level, 2);
		center_quant_dequant(qcenter, center, diff, prev_qcenter);

		float err = quantize_pixels_etc1_half(&qbits, half_pixels, center, table_level);

		if (err < best_error)
		{
			best_error = err;
			best_table = table_level;
			best_qbits = qbits;
			for (uniform int p = 0; p < 3; p++)
				best_qcenter[p] = qcenter[p];
		}
	}
    
	out_table[0] = best_table;
	out_qbits[0] = best_qbits;
	for (uniform int p = 0; p < 3; p++)
		out_qcenter[p] = best_qcenter[p];
	return best_error;
}

float optimize_center(float colors[4][10], uniform int p, uniform int table_level)
{
	float best_center = 0;
	for (uniform int q = 0; q < 4; q++)
		best_center += (colors[q][7 + p] - get_etc1_dY(table_level, q)) * colors[q][3];
	best_center /= 8;

	float best_err = 0;
	for (uniform int q = 0; q < 4; q++)
	{
		float dY = get_etc1_dY(table_level, q);
		best_err += sq(clamp(best_center + dY, 0, 255) - colors[q][7 + p]) * colors[q][3];
	}

	for (uniform int branch = 0; branch < 4; branch++)
	{
		float new_center = 0;
		float sum = 0;
		for (uniform int q = 0; q < 4; q++)
		{
			if (branch <= 1 && q <= branch)
				continue;
			if (branch >= 2 && q >= branch)
				continue;

			new_center += (colors[q][7 + p] - get_etc1_dY(table_level, q)) * colors[q][3];
			sum += colors[q][3];
		}

		new_center /= sum;

		float err = 0;
		for (uniform int q = 0; q < 4; q++)
		{
			float dY = get_etc1_dY(table_level, q);
			err += sq(clamp(new_center + dY, 0, 255) - colors[q][7 + p]) * colors[q][3];
		}

		if (err < best_err)
		{
			best_err = err;
			best_center = new_center;
		}
	}

	return best_center;
}

float compress_etc1_half_7(uint32 out_qbits[1], int out_table[1], int out_qcenter[3], float half_pixels[], etc_enc_state state[])
{
	int err_list[165];
	int y_sorted_inv[8];
	float y_sorted[8];

	{
		int y_sorted_idx[8];
		for (uniform int k = 0; k < 8; k++)
		{
			float value = 0;
			for (uniform int p = 0; p < 3; p++)
				value += half_pixels[k + p * 16];

			y_sorted_idx[k] = (((int)value) << 4) + k;
		}

		partial_sort_list(y_sorted_idx, 8, 8);

		for (uniform int k = 0; k < 8; k++)
			y_sorted_inv[k] = ((y_sorted_idx[k] & 0xF) << 4) + k;

		for (uniform int k = 0; k < 8; k++)
			y_sorted[k] = (y_sorted_idx[k] >> 4) / 3.0f;

		partial_sort_list(y_sorted_inv, 8, 8);
	}

	uniform int idx = -1;
	for (uniform int level1 = 0; level1 <= 8; level1++)
	{
		for (uniform int level2 = level1; level2 <= 8; level2++)
		{
			for (uniform int level3 = level2; level3 <= 8; level3++)
			{
				idx++;
				assert(idx < 165);
        
				float sum[4];
				float sum_sq[4];
				float count[4];
				float inv_count[4];

				for (uniform int q = 0; q < 4; q++)
				{
					sum[q] = 0;
					sum_sq[q] = 0;
					count[q] = 0;
					inv_count[q] = 0;
				}

				for (uniform int k = 0; k < 8; k++)
				{
					uniform int q = 0;
					if (k >= level1) q = 1;
					if (k >= level2) q = 2;
					if (k >= level3) q = 3;

					sum[q] += y_sorted[k];
					sum_sq[q] += sq(y_sorted[k]);
					count[q] += 1;
				}

				for (uniform int q = 0; q < 4; q++)
				{
					if (count[q] > 0)
						inv_count[q] = 1 / count[q];
				}

				float base_err = 0;
				for (uniform int q = 0; q < 4; q++)
					base_err += sum_sq[q] - sq(sum[q]) * inv_count[q];

				float t_err = sq(256) * 8;        
				for (uniform int table_level = 0; table_level < 8; table_level++)
				{
					float center = 0;
					for (uniform int q = 0; q < 4; q++) center += sum[q] - get_etc1_dY(table_level, q) * count[q];
					center /= 8;

					float err = base_err;
					for (uniform int q = 0; q < 4; q++)
					{
						err += sq(center + get_etc1_dY(table_level, q) - sum[q] * inv_count[q])*count[q];
					}

					t_err = min(t_err, err);
				}

				int packed = (level1 * 16 + level2) * 16 + level3;

				err_list[idx] = (((int)t_err) << 12) + packed;
			}
		}
	}

	partial_sort_list(err_list, 165, state->fastSkipTreshold);

	float best_error = sq(255) * 3 * 8.0f;
	int best_table = -1;
	int best_qcenter[3];
	uint32 best_qbits;

	for (uniform int i = 0; i < state->fastSkipTreshold; i++)
	{
		int packed = err_list[i] & 0xFFF;
		int level1 = (packed >> 8) & 0xF;
		int level2 = (packed >> 4) & 0xF;
		int level3 = (packed >> 0) & 0xF;
                
		float colors[4][10];

		for (uniform int p = 0; p < 7; p++)
			for (uniform int q = 0; q < 4; q++)
				colors[q][p] = 0;

		uint32 qbits = 0;
		for (uniform int kk = 0; kk < 8; kk++)
		{
			int k = y_sorted_inv[kk] & 0xF;

			int qq = 0;
			if (k >= level1)
				qq = 1;
			if (k >= level2)
				qq = 2;
			if (k >= level3)
				qq = 3;

			uniform int xx = kk & 3;
			uniform int yy = kk >> 2;

			int qqq = get_remap2_q(qq);
			qbits |= (qqq & 1) << (yy + xx * 4);
			qbits |= (qqq >> 1) << (16 + yy + xx * 4);

			float qvec[4];
			for (uniform int q = 0; q < 4; q++)
			{
				qvec[q] = q == qq ? 1.0 : 0.0;
				colors[q][3] += qvec[q];
			}

			for (uniform int p = 0; p < 3; p++)
			{
				float value = half_pixels[16 * p + kk];
				for (uniform int q = 0; q < 4; q++)
				{
					colors[q][p] += value * qvec[q];
					colors[q][4 + p] += sq(value) * qvec[q];
				}
			}
		}
        
		float base_err = 0;
		for (uniform int q = 0; q < 4; q++)
		{
			if (colors[q][3] > 0)
			for (uniform int p = 0; p < 3; p++)
			{
				colors[q][7 + p] = colors[q][p] / colors[q][3];
				base_err += colors[q][4 + p] - sq(colors[q][7 + p])*colors[q][3];
			}
		}

		for (uniform int table_level = 0; table_level < 8; table_level++)
		{
			float center[3];
			int qcenter[3];
            
			for (uniform int p = 0; p < 3; p++)
				center[p] = optimize_center(colors, p, table_level);
            
			center_quant_dequant(qcenter, center, state->diff, state->prev_qcenter);
            
			float err = base_err;
			for (uniform int q = 0; q < 4; q++)
			{
				int dY = get_etc1_dY(table_level, q);
				for (uniform int p = 0; p < 3; p++)
				err += sq(clamp(center[p] + dY, 0, 255) - colors[q][7 + p])*colors[q][3];
			}
            
			if (err < best_error)
			{
				best_error = err;
				best_table = table_level;
				best_qbits = qbits;
				for (uniform int p = 0; p < 3; p++)
					best_qcenter[p] = qcenter[p];
			}
		}
	}

	out_table[0] = best_table;
	out_qbits[0] = best_qbits;
	for (uniform int p = 0; p < 3; p++)
		out_qcenter[p] = best_qcenter[p];
	return best_error;
}

float compress_etc1_half(uint32 qbits[1], int table[1], int qcenter[3], float half_pixels[], etc_enc_state state[])
{
	float err = compress_etc1_half_7(qbits, table, qcenter, half_pixels, state);

	for (uniform int p = 0; p < 3; p++)
		state->prev_qcenter[p] = qcenter[p];

	return err;
}

//////////////////////////
//       ETC1 core

void etc_pack(uint32 data[], uint32 qbits[2], int tables[2], int qcenters[2][3], uniform int diff, uniform int flip)
{
	for (uniform int k = 0; k < 2; k++) data[k] = 0;
	uniform int pos = 0;

	if (diff == 0)
	{
		put_bits(data, &pos, 4, qcenters[1][0]);
		put_bits(data, &pos, 4, qcenters[0][0]);

		put_bits(data, &pos, 4, qcenters[1][1]);
		put_bits(data, &pos, 4, qcenters[0][1]);

		put_bits(data, &pos, 4, qcenters[1][2]);
		put_bits(data, &pos, 4, qcenters[0][2]);
	}
	else
	{
		put_bits(data, &pos, 3, (qcenters[1][0] - qcenters[0][0]) & 7);
		put_bits(data, &pos, 5, qcenters[0][0]);

		put_bits(data, &pos, 3, (qcenters[1][1] - qcenters[0][1]) & 7);
		put_bits(data, &pos, 5, qcenters[0][1]);

		put_bits(data, &pos, 3, (qcenters[1][2] - qcenters[0][2]) & 7);
		put_bits(data, &pos, 5, qcenters[0][2]);
	}

	put_bits(data, &pos, 1, flip);
	put_bits(data, &pos, 1, diff);
	put_bits(data, &pos, 3, tables[1]);
	put_bits(data, &pos, 3, tables[0]);

	uint32 all_qbits_flipped = (qbits[1] << 2) | qbits[0];
	uint32 all_qbits = 0;

	if (flip != 0)
		all_qbits = all_qbits_flipped;

	if (flip == 0)
	{
		for (uniform int k = 0; k < 2; k++)
		{
			for (uniform int y = 0; y < 4; y++)
			{
				for (uniform int x = 0; x < 4; x++)
				{
					int bit = (all_qbits_flipped >> (k * 16 + x * 4 + y)) & 1;
					all_qbits += bit << (k * 16 + y * 4 + x);
				}
			}
		}
	}

	data[1] = bswap32(all_qbits);
}

inline void CompressBlockETC1_core(etc_enc_state state[])
{
	float flipped_block[48];

	for (uniform int y = 0; y < 4; y++)
		for (uniform int x = 0; x < 4; x++)
			for (uniform int p = 0; p < 3; p++)
				flipped_block[16 * p + x * 4 + y] = state->block[16 * p + y * 4 + x];

	for (uniform int flip = 0; flip < 2; flip++)
	{
		for (uniform int diff = 1; diff >= 0; diff--)
		{
			state->diff = diff == 1;
			state->prev_qcenter[0] = -1;

			varying float * uniform pixels = state->block;
			if (flip == 0)
				pixels = flipped_block;

			uint32 qbits[2];
			int tables[2];
			int qcenters[2][3];

			float err = 0;
			err += compress_etc1_half(&qbits[0], &tables[0], qcenters[0], &pixels[0], state);
			err += compress_etc1_half(&qbits[1], &tables[1], qcenters[1], &pixels[8], state);

			if (err < state->best_err)
			{
				state->best_err = err;
				etc_pack(state->best_data, qbits, tables, qcenters, diff, flip);
			}
		}
	}
}

void etc_enc_copy_settings(etc_enc_state state[], uniform etc_enc_settings settings[])
{
	state->fastSkipTreshold = settings->fastSkipTreshold;
}

///////////////////////////////////////////////////////////
// High level per block handling.
//

inline void CompressBlockETC1( etc_enc_state EncState[], uniform etc_enc_settings EncSettings[] )
{
	etc_enc_copy_settings( EncState, EncSettings );
	EncState->best_err = 1e99;

	CompressBlockETC1_core( EncState );
}

///////////////////////////////////////////////////////////
// Dispatcher from input surface to block level.
//
// Templates would be nice here, but not in ispc, maybe preprocessor macros?
// Are there function pointers available in ispc?
// 

// ETC1.
inline void LoadCompressStoreBlockETC1_RGBA8( uniform Surface_RGBA8 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[], uniform etc_enc_settings EncSettings[] )
{
	etc_enc_state EncState;

	LoadUncompressed4x4BlockInterleavedNoAlpha_RGBA8( EncState.block, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockETC1( &EncState, EncSettings );
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, EncState.best_data, 2 );
}
inline void LoadCompressStoreBlockETC1_RGBA16( uniform Surface_RGBA16 InputSurface[], int HorizontalBlockIndex, uniform int VerticalBlockIndex, uniform uint8 OutputBlocks[], uniform etc_enc_settings EncSettings[] )
{
	etc_enc_state EncState;

	LoadUncompressed4x4BlockInterleavedNoAlpha_RGBA16( EncState.block, InputSurface, HorizontalBlockIndex, VerticalBlockIndex );
	CompressBlockETC1( &EncState, EncSettings );
	StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, EncState.best_data, 2 );
}

export void ETC1_Compress_RGBA8( uniform Surface_RGBA8 InputSurface[], uniform uint8 OutputBlocks[], uniform etc_enc_settings EncSettings[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockETC1_RGBA8( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks, EncSettings );
}
export void ETC1_Compress_RGBA16( uniform Surface_RGBA16 InputSurface[], uniform uint8 OutputBlocks[], uniform etc_enc_settings EncSettings[] )
{	
	uniform int NumHorizontalBlocks = InputSurface->Width/4;
	uniform int NumVerticalBlocks   = InputSurface->Height/4;

	for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ )
		foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks )
			LoadCompressStoreBlockETC1_RGBA16( InputSurface, HorizontalBlockIndex, VerticalBlockIndex, OutputBlocks, EncSettings );
}
