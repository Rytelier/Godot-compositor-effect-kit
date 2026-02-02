# Godot compositor effect kit
Create and debug compositor effects quickly

## Base compositor effect class
Quickly setup a compositor effect with much less boilerplate code.

An example of an effect script:

```gdscript
@tool
extends R_BaseCompositorEffect
class_name EffectGreyscale


@export_range(0, 1, 0.001) var amount: float = 1: 
	set(v):
		amount = v
		update_push_constant() # Change constant data when value is modified


# Shader and pipeline created on initialization
const shader_path = "res://Compositor/Demo greyscale/post_process_grayscale.glsl"
var shader: RID
var pipeline: RID

var push_constant: PackedByteArray # Push constant dara refreshed by changing screen size or amount value


# When effect is added, before initializing render
func _initialize_resource() -> void:
	workgroup_size_default = 8 # Override workgroup size on initialize


# Initialize shader, pipeline, constants, custom samplers here
func _initialize_render() -> void:
	shader = create_shader(shader_path)
	pipeline = create_pipeline(shader)
	
	update_push_constant()


# Called before running the shader
func _render_setup() -> void:
	pass


# Running the shader goes here
func _render_view(view : int) -> void:
	run_compute_shader("Greyscale", shader, pipeline,
		[[
			get_color_image_uniform(view, 0),
		]],
		push_constant)


# Update constants on viewport size change
func _render_size_changed() -> void:
	update_push_constant()


func update_push_constant() -> void:
	push_constant = create_push_constant([render_size.x, render_size.y, amount])

```

## Texture previewer
Texture preview compositor effect allows you to quickly preview a scene buffer or custom texture created in a compositor effect script.

## Scene data shader include
Shader include file with scene data uniforms to use in your shader.

## Templates
Package includes a shader and script templates for quick start in making your effects.

See `Compositor effect template.txt` and `Shader template.glsl`

## Credits
[Modified BaseCompositorEffect and scene data include by Pink Arcana](https://github.com/pink-arcana/godot-distance-field-outlines/tree/main)