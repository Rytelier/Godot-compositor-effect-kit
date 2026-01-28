@tool
@abstract
class_name R_BaseCompositorEffect
extends CompositorEffect


@export_subgroup("Debug")
@export var print_buffer_resize: bool = false
## Use to troubleshoot errors from freeing invalid RIDs.
@export var print_freed_rids: bool = false


var nearest_sampler: RID
var linear_sampler: RID

var workgroup_size_default: int = 16

var rd: RenderingDevice
var render_data: RenderData
var render_scene_data: RenderSceneData
var render_scene_buffers: RenderSceneBuffersRD


var render_size := Vector2i.ZERO:
	set(value):
		if value == render_size:
			return
		render_size = value
		_render_size_changed()


var _workgroups := Vector3i.ZERO

var _rids_to_free := {} # {rid: label}
var _shader_file_paths: PackedStringArray


#region Abstact functions
## Abstract function. Called from _init(). Use this function to set up components
## of this resource that are unrelated to the rendering thread.
@abstract func _initialize_resource() -> void

## Abstract function. Called on render thread after _init(). Use this function
## to set up components associated with the rendering thread, such as samplers,
## shaders and pipelines.
@abstract func _initialize_render() -> void

## Called at beginning of _render_callback(), after updating render variables
## and after _render_size_changed().
## Use this function to validate and setup textures or uniforms.
@abstract func _render_setup() -> void

## Called for each view. Run the compute shaders from here.
@abstract func _render_view(view: int) -> void

## Called before _render_setup() if `render_size` has changed.
@abstract func _render_size_changed() -> void
#endregion


#region Essentials
func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		for rid: RID in _rids_to_free:
			if rid.is_valid():
				if print_freed_rids:
					print("freeing RID: %s: %s" % [rid.get_id(), _rids_to_free[rid]])
				rd.free_rid(rid)
		_rids_to_free.clear()
		
		if Engine.is_editor_hint():
			EditorInterface.get_resource_filesystem().resources_reimported.disconnect(_reload.bind())


func _clean_rids() -> void: # Repeated because calling this function on game exit gives null error
	for rid: RID in _rids_to_free:
		if rid.is_valid():
			if print_freed_rids:
				print("freeing RID: %s: %s" % [rid.get_id(), _rids_to_free[rid]])
			rd.free_rid(rid)
	_rids_to_free.clear()


func _init():
	_initialize_resource()
	RenderingServer.call_on_render_thread(_initialize_render_base)
	
	if (Engine.is_editor_hint() and not EditorInterface.get_resource_filesystem().resources_reimported.is_connected(_reload.bind())):
		EditorInterface.get_resource_filesystem().resources_reimported.connect(_reload.bind())


func _reload(files: PackedStringArray):
	for file in files:
		if _shader_file_paths.has(file):
			_clean_rids()
			_initialize_resource()
			RenderingServer.call_on_render_thread(_initialize_render_base)
			return


func _initialize_render_base() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		return

	nearest_sampler = create_sampler(RenderingDevice.SamplerFilter.SAMPLER_FILTER_NEAREST)
	linear_sampler = create_sampler(RenderingDevice.SamplerFilter.SAMPLER_FILTER_LINEAR)

	_initialize_render()


func _render_callback(
		p_effect_callback_type: EffectCallbackType,
		p_render_data: RenderData,
	) -> void:

	if not rd or not p_effect_callback_type == effect_callback_type:
		return

	render_data = p_render_data
	render_scene_buffers = p_render_data.get_render_scene_buffers()
	render_scene_data = p_render_data.get_render_scene_data()

	if not render_scene_buffers or not render_scene_data:
		return

	render_size = render_scene_buffers.get_internal_size()
	if render_size.x == 0 or render_size.y == 0:
		return

	set_workgroups(workgroup_size_default)

	_render_setup()

	for view in render_scene_buffers.get_view_count():
		_render_view(view)
#endregion


#region Helpers
func add_rid_to_free(p_rid: RID, p_label: String = "") -> void:
	_rids_to_free[p_rid] = p_label


## rid.is_valid() returns true for previously freed rids.
## This function is used to track rids as they are freed to prevent errors
## when attempting to free them.
func free_rid(p_rid: RID) -> void:
	_rids_to_free.erase(p_rid)
	if p_rid.is_valid():
		rd.free_rid(p_rid)
		if print_freed_rids:
			print("freeing RID: %s: %s" % [p_rid.get_id(), _rids_to_free[p_rid]])


func create_sampler(
		p_filter: RenderingDevice.SamplerFilter,
		p_repeat_mode := RenderingDevice.SamplerRepeatMode.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE,
	) -> RID:
	
	var sampler_state: RDSamplerState = RDSamplerState.new()
	sampler_state.min_filter = p_filter
	sampler_state.mag_filter = p_filter
	sampler_state.repeat_u = p_repeat_mode
	sampler_state.repeat_v = p_repeat_mode
	sampler_state.repeat_w = p_repeat_mode
	var sampler: RID = rd.sampler_create(sampler_state)
	add_rid_to_free(sampler, "sampler")
	
	return sampler


## Create shader from imported glsl file path.
func create_shader(p_file_path: String) -> RID:
	var shader_file: RDShaderFile = load(p_file_path)
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	var shader: RID = rd.shader_create_from_spirv(shader_spirv)
	add_rid_to_free(shader, "shader: %s" % p_file_path)
	_shader_file_paths.append(p_file_path)
	
	return shader


## For loading shader file + replacing its defines.
## When not using defines use 'create_shader' instead.
func compile_shader_from_text(p_file_path: String, p_replace_lines: Dictionary[String, String]) -> RID:
	var code: String = FileAccess.open(p_file_path, FileAccess.READ).get_as_text()
	
	code = code.replace("#[compute]", "") # Needs to be in imported file, but not for compiling
	for key in p_replace_lines.keys():
		code = code.replace(key, p_replace_lines[key])
	
	var source: RDShaderSource = RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = code
	
	var spirv = rd.shader_compile_spirv_from_source(source)
	if spirv.compile_error_compute != "":
		var text = source.source_compute.replace("\n", "\r\b") # Fix line separation in print
		printerr(spirv.compile_error_compute + "\n")
		print(text)
		
		return RID()
	
	var shader = rd.shader_create_from_spirv(spirv)
	add_rid_to_free(shader, "shader: %s" % p_file_path)
	
	return shader


## Use after 'create_shader' or 'compile_shader_from_text'.
## p_constants is a dictionary of {int: bool/int/float}.
func create_pipeline(p_shader: RID, p_constants := {}) -> RID:
	if not p_shader.is_valid():
		push_error("Shader is not valid")
		return RID()

	var constants: Array[RDPipelineSpecializationConstant] = []
	for key in p_constants:
		assert(typeof(key) == TYPE_INT)
		assert(typeof(p_constants[key]) in [TYPE_INT, TYPE_FLOAT, TYPE_BOOL])
		var constant := RDPipelineSpecializationConstant.new()
		constant.constant_id = key
		constant.value = p_constants[key]
		constants.append(constant)

	return rd.compute_pipeline_create(p_shader, constants)


## Creates a unique texture with 1 layer, 1 mipmap, and TEXTURE_SAMPLES_1.
## Returns the image RID.
func create_texture_scene_buffer(
		p_context: StringName,
		p_texture_name: StringName,
		p_format: RenderingDevice.DataFormat,
		p_usage_bits: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
		p_texture_size := Vector2i.ZERO,
	) -> RID:

	const TEXTURE_SAMPLES := RenderingDevice.TextureSamples.TEXTURE_SAMPLES_1
	const TEXTURE_LAYER_COUNT: int = 1
	const TEXTURE_MIPMAP_COUNT: int = 1
	const TEXTURE_LAYER: int = 0
	const TEXTURE_MIPMAP: int = 0
	const TEXTURE_IS_UNIQUE: bool = true

	var texture_size := render_size if p_texture_size == Vector2i.ZERO else p_texture_size

	render_scene_buffers.create_texture(
			p_context,
			p_texture_name,
			p_format,
			p_usage_bits,
			TEXTURE_SAMPLES,
			texture_size,
			TEXTURE_LAYER_COUNT,
			TEXTURE_MIPMAP_COUNT,
			TEXTURE_IS_UNIQUE,
			true
	)

	var texture_image: RID = render_scene_buffers.get_texture_slice(
			p_context,
			p_texture_name,
			TEXTURE_LAYER,
			TEXTURE_MIPMAP,
			TEXTURE_LAYER_COUNT,
			TEXTURE_MIPMAP_COUNT,
	)

	# Textures appear to be automatically freed at the time of NOTIFICATION_PREDELETE.
	# Attempting to free the texture's RID will trigger errors.
	# So we will not add its RID to rids_to_free.
	add_rid_to_free(texture_image, "tex scene buffer " + str(_rids_to_free.size()))
	return texture_image


func create_texture(
		p_texture_size: Vector2i = Vector2i.ZERO, 
		p_format: RenderingDevice.DataFormat = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		p_usage_bits: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
		) -> RID:
	var texture: RID = rd.texture_create(
		get_texture_format(p_texture_size if p_texture_size != Vector2i.ZERO else render_size,
		p_format, p_usage_bits)
		, RDTextureView.new())
	add_rid_to_free(texture, "tex " + str(_rids_to_free.size()))
	return texture


func get_texture_format(p_texture_size: Vector2i, p_format: RenderingDevice.DataFormat, p_usage_bits: int) -> RDTextureFormat:
	var texture_format := RDTextureFormat.new()
	texture_format.width = p_texture_size.x
	texture_format.height = p_texture_size.y
	texture_format.format = p_format
	texture_format.usage_bits = p_usage_bits
	
	return texture_format


## Individual assignments in a uniform buffer must be aligned to 16 bytes.
## However, you can assign the whole buffer to a struct, and that struct can contain
## elements aligned at 4 bytes (== one 32-bit float, which is the smallest data size
## for uniforms).
##
## Vector4's must be aligned to 16 bytes, so it is best to put them first in the list.
##
## Automatic conversion for Vector2's and Vector3's is not included here.
## We should convert them to Vector4 manually so we can keep track of their alignment.
func create_uniform_buffer(p_data: Array) -> RID:
	var buffer_data: PackedByteArray

	for value in p_data:
		var type := typeof(value)
		var byte_array: PackedByteArray
		match type:
			TYPE_INT:
				# PackedInt32Array does not convert the values as expected.
				byte_array = PackedFloat32Array([float(value)]).to_byte_array()
			TYPE_BOOL:
				byte_array = PackedFloat32Array([float(value)]).to_byte_array()
			TYPE_FLOAT:
				byte_array = PackedFloat32Array([value]).to_byte_array()
			TYPE_COLOR:
				byte_array = PackedColorArray([value]).to_byte_array()
			TYPE_VECTOR4:
				byte_array = PackedVector4Array([value]).to_byte_array()
			TYPE_VECTOR4I:
				byte_array = PackedVector4Array([Vector4(value)]).to_byte_array()
			_:
				push_error("[DFOutlineCE:create_uniform_buffer()] Unhandled data type found: %s" % type)
				continue

		buffer_data.append_array(byte_array)

	var size_before := buffer_data.size()

	# Resize to a multiple of 16 bytes.
	if buffer_data.size() % 16:
		var divisor := floori(float(buffer_data.size()) / 16.0)
		buffer_data.resize((divisor + 1) * 16)

	if print_buffer_resize:
		var size_change := buffer_data.size() - size_before
		print("UBO buffer resized from %s to %s." % [size_before, buffer_data.size()])
		print("\tBytes added: %s = %s floats." % [size_change, float(size_change)/4.0])

	var ubo: RID = rd.uniform_buffer_create(buffer_data.size(), buffer_data)
	add_rid_to_free(ubo, "ubo")
	return ubo


func get_uniform_buffer_uniform(p_rid: RID, p_binding: int) -> RDUniform:
	var uniform  := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = p_binding
	uniform.add_id(p_rid)
	return uniform


func get_image_uniform(p_image_rid: RID, p_binding: int = 0) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = p_binding
	uniform.add_id(p_image_rid)
	return uniform


func get_sampler_uniform(p_image_rid: RID, p_sampler: RID, p_binding: int = 0, ) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = p_binding
	uniform.add_id(p_sampler)
	uniform.add_id(p_image_rid)
	return uniform


## `p_push_constant` takes a PackedFloat32Array and resizes
## it to meet layout requirements. Push constants use std430, so the items
## don't require padding for alignment. But it appears the total size must be
## a multiple of 16 bytes.
func run_compute_shader(p_label: String, p_shader: RID,
	p_pipeline: RID, p_uniform_sets: Array[Array], p_push_constant: PackedByteArray,) -> void:

	rd.draw_command_begin_label(p_label, Color.AQUAMARINE)

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, p_pipeline)

	for idx in p_uniform_sets.size():
		var uniforms: Array = p_uniform_sets[idx]
		rd.compute_list_bind_uniform_set(compute_list,
			UniformSetCacheRD.get_cache(p_shader, idx, uniforms),
			idx,
		)

	rd.compute_list_set_push_constant(
			compute_list,
			p_push_constant,
			p_push_constant.size(),
		)

	rd.compute_list_dispatch(compute_list, _workgroups.x, _workgroups.y, _workgroups.z)
	rd.compute_list_end()
	rd.draw_command_end_label()


func create_push_constant(p_push_constant: PackedFloat32Array) -> PackedByteArray:
	var byte_array: PackedByteArray = p_push_constant.to_byte_array()
	var size_before: int = byte_array.size()
	if byte_array.size() % 16:
		byte_array.resize(ceili(float(byte_array.size())/16.0) * 16)
		if print_buffer_resize:
			var size_change := byte_array.size() - size_before
			print("\tPush constant resized from %s to %s." % [size_before, byte_array.size()])
			print("\tBytes added: %s = %s floats." % [size_change, float(size_change)/4.0])
	
	return byte_array


## Get Godot's built-in SceneData uniform buffer which includes values for projection and view matrix,
## environment values, camera data and other render info.
## Use include file from 'Includes' folder
## See https://github.com/godotengine/godot/pull/80214#issuecomment-1953258434
func get_scene_data_ubo(p_binding: int) -> RDUniform:
	if not render_scene_data:
		return null

	var scene_data_buffer: RID = render_scene_data.get_uniform_buffer()
	var scene_data_buffer_uniform := RDUniform.new()
	scene_data_buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	scene_data_buffer_uniform.binding = p_binding
	scene_data_buffer_uniform.add_id(scene_data_buffer)
	return scene_data_buffer_uniform


func get_color_image_uniform(p_view: int, p_binding: int) -> RDUniform:
	var color_image: RID = render_scene_buffers.get_color_layer(p_view)
	var color_image_uniform: RDUniform = get_image_uniform(
			color_image,
			p_binding,
		)
	return color_image_uniform


func get_color_sampler_uniform(p_view: int, p_sampler: RID, p_binding: int) -> RDUniform:
	var color_image: RID = render_scene_buffers.get_color_layer(p_view)
	var color_image_uniform: RDUniform = get_sampler_uniform(
			color_image,
			p_sampler,
			p_binding,
		)
	return color_image_uniform


func get_depth_sampler_uniform(p_view: int, p_sampler: RID, p_binding: int) -> RDUniform:
	var depth_image: RID = render_scene_buffers.get_depth_layer(p_view)
	var depth_sampler_uniform: RDUniform = get_sampler_uniform(
			depth_image,
			p_sampler,
			p_binding,
		)
	return depth_sampler_uniform


func get_normal_sampler_uniform(p_sampler: RID, p_binding: int) -> RDUniform:
	var normal_image: RID = render_scene_buffers.get_texture(
			"forward_clustered",
			"normal_roughness"
		)
	var normal_sampler_uniform: RDUniform = get_sampler_uniform(
			normal_image,
			p_sampler,
			p_binding,
	)
	return normal_sampler_uniform


## Called on render function start, use it to change to different size when shader pass requires it.
func set_workgroups(size: int) -> void:
	_workgroups = Vector3i(
		ceil(((float(render_size.x) - 1) / size) + 1),
		ceil(((float(render_size.y) - 1) / size) + 1),
		1,
	)


func get_projection(inverse: bool, view: int) -> PackedFloat32Array:
	var view_proj = render_scene_data.get_view_projection(view)
	if inverse: view_proj = view_proj.inverse()
	return PackedFloat32Array([
		view_proj.x.x, view_proj.x.y, view_proj.x.z, view_proj.x.w, 
		view_proj.y.x, view_proj.y.y, view_proj.y.z, view_proj.y.w, 
		view_proj.z.x, view_proj.z.y, view_proj.z.z, view_proj.z.w, 
		view_proj.w.x, view_proj.w.y, view_proj.w.z, view_proj.w.w, 
	])
#endregion
