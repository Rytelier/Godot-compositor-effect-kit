#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, binding = 0) uniform restrict writeonly image2D image_out;
layout(binding = 1) uniform sampler2D image_in;

layout(push_constant, std430) uniform Params {
	vec2 size;
	float channel;
	float _;
} params;


void main() {
	
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);

	vec4 img = texture(image_in, coord / vec2(params.size.x, params.size.y));
	int channel = int(params.channel);

	if(channel == -1){
		imageStore(image_out, coord, img);}
	else{
		imageStore(image_out, coord, vec4(vec3(img[channel]), 1));}
}