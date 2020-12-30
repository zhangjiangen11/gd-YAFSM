tool
extends Control

const Utils = preload("res://addons/imjp94.yafsm/scripts/Utils.gd")
const CohenSutherland = Utils.CohenSutherland
const FlowChartNode = preload("FlowChartNode.gd")
const FlowChartNodeScene = preload("FlowChartNode.tscn")
const FlowChartLine = preload("FlowChartLine.gd")
const FlowChartLineScene = preload("FlowChartLine.tscn")

signal connection(from, to, line)
signal disconnection(from, to, line)
signal node_selected(node)
signal node_deselected(node)
signal dragged(node, distance)

export var scroll_margin = 100
export var interconnection_offset = 10
export var snap = 20

var content = Control.new()
var content_lines = Control.new() # Node that hold all flowchart lines
var content_nodes = Control.new() # Node that hold all flowchart nodes
var h_scroll
var v_scroll
var gadget
var zoom_minus = Button.new()
var zoom_reset = Button.new()
var zoom_plus = Button.new()
var snap_button = Button.new()
var snap_amount = SpinBox.new()

var is_snapping = true

var _connections = {}
var _is_connecting = false
var _current_connection
var _is_dragging = false
var _is_dragging_node = false
var _drag_start_pos = Vector2.ZERO
var _drag_end_pos = Vector2.ZERO
var _drag_origins = []
var _selection = []
var _copying_nodes = []

var selection_stylebox = StyleBoxFlat.new()
var grid_major_color = Color(1, 1, 1, 0.15)
var grid_minor_color = Color(1, 1, 1, 0.07)
	

func _init():
	focus_mode = FOCUS_ALL
	selection_stylebox.bg_color = Color(0, 0, 0, 0.3)
	selection_stylebox.set_border_width_all(1)

func _ready():
	h_scroll = HScrollBar.new()
	add_child(h_scroll)
	h_scroll.set_anchors_and_margins_preset(PRESET_BOTTOM_WIDE)
	h_scroll.connect("value_changed", self, "_on_h_scroll_changed")
	h_scroll.connect("gui_input", self, "_on_h_scroll_gui_input")

	v_scroll = VScrollBar.new()
	add_child(v_scroll)
	v_scroll.set_anchors_and_margins_preset(PRESET_RIGHT_WIDE)
	v_scroll.connect("value_changed", self, "_on_v_scroll_changed")
	v_scroll.connect("gui_input", self, "_on_v_scroll_gui_input")

	h_scroll.margin_right = -v_scroll.rect_size.x
	v_scroll.margin_bottom = -h_scroll.rect_size.y

	content.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(content)

	content_lines.name = "content_lines"
	content_lines.mouse_filter = MOUSE_FILTER_IGNORE
	content.add_child(content_lines)
	content.move_child(content_lines, 0) # Make sure content_lines always behind nodes

	content_nodes.name = "content_nodes"
	content_nodes.mouse_filter = MOUSE_FILTER_IGNORE
	content.add_child(content_nodes)

	gadget = HBoxContainer.new()
	gadget.set_anchors_and_margins_preset(PRESET_TOP_WIDE)
	add_child(gadget)

	zoom_minus.flat = true
	zoom_minus.hint_tooltip = "Zoom Out"
	zoom_minus.connect("pressed", self, "_on_zoom_minus_pressed")
	zoom_minus.focus_mode = FOCUS_NONE
	gadget.add_child(zoom_minus)

	zoom_reset.flat = true
	zoom_reset.hint_tooltip = "Zoom Reset"
	zoom_reset.connect("pressed", self, "_on_zoom_reset_pressed")
	zoom_reset.focus_mode = FOCUS_NONE
	gadget.add_child(zoom_reset)

	zoom_plus.flat = true
	zoom_plus.hint_tooltip = "Zoom In"
	zoom_plus.connect("pressed", self, "_on_zoom_plus_pressed")
	zoom_plus.focus_mode = FOCUS_NONE
	gadget.add_child(zoom_plus)

	snap_button.flat = true
	snap_button.toggle_mode = true
	snap_button.hint_tooltip = "Enable snap and show grid"
	snap_button.connect("pressed", self, "_on_snap_button_pressed")
	snap_button.pressed = true
	snap_button.focus_mode = FOCUS_NONE
	gadget.add_child(snap_button)

	snap_amount.value = snap
	snap_amount.connect("value_changed", self, "_on_snap_amount_value_changed")
	gadget.add_child(snap_amount)

func _on_h_scroll_gui_input(event):
	if event is InputEventMouseButton:
		var v = (h_scroll.max_value - h_scroll.min_value) * 0.01 # Scroll at 0.1% step
		match event.button_index:
			BUTTON_WHEEL_UP:
				h_scroll.value -= v
			BUTTON_WHEEL_DOWN:
				h_scroll.value += v

func _on_v_scroll_gui_input(event):
	if event is InputEventMouseButton:
		var v = (v_scroll.max_value - v_scroll.min_value) * 0.01 # Scroll at 0.1% step
		match event.button_index:
			BUTTON_WHEEL_UP:
				v_scroll.value -= v # scroll left
			BUTTON_WHEEL_DOWN:
				v_scroll.value += v # scroll right

func _on_zoom_minus_pressed():
	content.rect_scale -= Vector2.ONE * 0.1
	update()

func _on_zoom_reset_pressed():
	content.rect_scale = Vector2.ONE
	update()

func _on_zoom_plus_pressed():
	content.rect_scale += Vector2.ONE * 0.1
	update()

func _on_snap_button_pressed():
	is_snapping = snap_button.pressed
	update()

func _on_snap_amount_value_changed(value):
	snap = value
	update()

func _notification(what):
	match what:
		NOTIFICATION_DRAW:
			var content_rect = get_scroll_rect()
			content.rect_pivot_offset = get_scroll_rect().size / 2.0 # Scale from center
			if not get_rect().encloses(content_rect):
				h_scroll.min_value = content_rect.position.x
				h_scroll.max_value = content_rect.size.x + content_rect.position.x - rect_size.x
				h_scroll.page = content_rect.size.x / 100
				v_scroll.min_value = content_rect.position.y
				v_scroll.max_value = content_rect.size.y + content_rect.position.y - rect_size.y
				v_scroll.page = content_rect.size.y / 100

			# Draw selection box
			if not _is_dragging_node and not _is_connecting:
				var selection_box_rect = get_selection_box_rect()
				draw_style_box(selection_stylebox, selection_box_rect)

			# Draw grid
			# Refer GraphEdit(https://github.com/godotengine/godot/blob/6019dab0b45e1291e556e6d9e01b625b5076cc3c/scene/gui/graph_edit.cpp#L442)
			if is_snapping:
				var zoom = (Vector2.ONE/content.rect_scale).length()
				var scroll_offset = Vector2(h_scroll.get_value(), v_scroll.get_value());
				var offset = scroll_offset / zoom
				var size = rect_size / zoom

				var from = (offset / float(snap)).floor()
				var l = (size / float(snap)).floor() + Vector2(1, 1)

				var  grid_minor = grid_minor_color
				var  grid_major = grid_major_color

				# for (int i = from.x; i < from.x + len.x; i++) {
				for i in range(from.x, from.x + l.x):
					var color

					if (int(abs(i)) % 10 == 0):
						color = grid_major
					else:
						color = grid_minor

					var base_ofs = i * snap * zoom - offset.x * zoom
					draw_line(Vector2(base_ofs, 0), Vector2(base_ofs, rect_size.y), color)

				# for (int i = from.y; i < from.y + len.y; i++) {
				for i in range(from.y, from.y + l.y):
					var color;

					if (int(abs(i)) % 10 == 0):
						color = grid_major
					else:
						color = grid_minor

					var base_ofs = i * snap * zoom - offset.y * zoom
					draw_line(Vector2(0, base_ofs), Vector2(rect_size.x, base_ofs), color)

			# Debug draw
			# for node in content_nodes.get_children():
			# 	var rect = get_transform().xform(content.get_transform().xform(node.get_rect()))
			# 	draw_style_box(selection_stylebox, rect)

			# var connection_list = get_connection_list()
			# for i in connection_list.size():
			# 	var connection = _connections[connection_list[i].from][connection_list[i].to]
			# 	# Line's offset along its down-vector
			# 	var line_local_up_offset = connection.line.rect_position - connection.line.get_transform().xform(Vector2.UP * connection.offset)
			# 	var from_pos = content.get_transform().xform(connection.get_from_pos() + line_local_up_offset)
			# 	var to_pos = content.get_transform().xform(connection.get_to_pos() + line_local_up_offset)
			# 	draw_line(from_pos, to_pos, Color.yellow)

func _on_h_scroll_changed(value):
	content.rect_position.x = -value

func _on_v_scroll_changed(value):
	content.rect_position.y = -value

func _gui_input(event):
	if event is InputEventKey:
		match event.scancode:
			KEY_DELETE:
				if event.pressed:
					for node in _selection.duplicate():
						if node is FlowChartLine:
							# TODO: More efficient way to get connection from Line node
							for connections_from in _connections.duplicate().values():
								for connection in connections_from.duplicate().values():
									if connection.line == node:
										disconnect_node(connection.from_node.name, connection.to_node.name)
						elif node is FlowChartNode:
							remove_node(node.name)
							for connection_pair in get_connection_list():
								if connection_pair.from == node.name or connection_pair.to == node.name:
									disconnect_node(connection_pair.from, connection_pair.to)
					accept_event()
			KEY_C:
				if event.pressed and event.control:
					# Copy node
					_copying_nodes = _selection.duplicate()
			KEY_D:
				if event.pressed and event.control:
					# Duplicate node directly from selection
					duplicate_nodes(_selection.duplicate())
			KEY_V:
				if event.pressed and event.control:
					# Paste node from _copying_nodes
					duplicate_nodes(_copying_nodes)

	if event is InputEventMouseButton:
		match event.button_index:
			BUTTON_MIDDLE:
				if event.doubleclick:
					content.rect_scale = Vector2.ONE
					update()
			BUTTON_WHEEL_UP:
				content.rect_scale += Vector2.ONE * 0.01
				update()
			BUTTON_WHEEL_DOWN:
				content.rect_scale -= Vector2.ONE * 0.01
				update()
	if event is InputEventMouseMotion:
		match event.button_mask:
			BUTTON_MASK_MIDDLE:
				h_scroll.value -= event.relative.x
				v_scroll.value -= event.relative.y
				update()
			BUTTON_LEFT:
				if _is_dragging:
					if _is_connecting:
						# Connecting
						if _current_connection:
							var pos = content_position(get_local_mouse_position())
							# Snapping connecting line
							for i in content_nodes.get_child_count():
								var child = content_nodes.get_child(content_nodes.get_child_count()-1 - i) # Inverse order to check from top to bottom of canvas
								if child is FlowChartNode and child.name != _current_connection.from_node.name:
									if child.get_rect().has_point(pos):
										pos = child.rect_position + child.rect_size / 2
										break
							_current_connection.line.join(_current_connection.get_from_pos(), pos)
					elif _is_dragging_node:
						# Dragging nodes
						var dragged = content_position(_drag_end_pos) - content_position(_drag_start_pos)
						for i in _selection.size():
							var selected = _selection[i]
							if not (selected is FlowChartNode):
								continue
							selected.rect_position = (_drag_origins[i] + dragged)
							if is_snapping:
								selected.rect_position = selected.rect_position.snapped(Vector2.ONE * snap)
							_on_node_dragged(selected, dragged)
							emit_signal("dragged", selected, dragged)
							# Update connection pos
							for from in _connections:
								var connections_from = _connections[from]
								for to in connections_from:
									if from == selected.name or to == selected.name:
										var connection = _connections[from][to]
										connection.join()
					_drag_end_pos = get_local_mouse_position()
					update()

	if event is InputEventMouseButton:
		var hit_node
		for i in content_nodes.get_child_count():
			var child = content_nodes.get_child(content_nodes.get_child_count()-1 - i) # Inverse order to check from top to bottom of canvas
			if child is FlowChartNode:
				if child.get_rect().has_point(content_position(event.position)):
					hit_node = child
					break
		if not hit_node:
			# Test Line
			# Refer https://github.com/godotengine/godot/blob/master/editor/plugins/animation_state_machine_editor.cpp#L187
			var closest = -1
			var closest_d = 1e20
			var connection_list = get_connection_list()
			for i in connection_list.size():
				var connection = _connections[connection_list[i].from][connection_list[i].to]
				# Line's offset along its down-vector
				var line_local_up_offset = connection.line.rect_position - connection.line.get_transform().xform(Vector2.DOWN * connection.offset)
				var from_pos = connection.get_from_pos() + line_local_up_offset
				var to_pos = connection.get_to_pos() + line_local_up_offset
				var cp = Geometry.get_closest_point_to_segment_2d(content_position(event.position), from_pos, to_pos)
				var d = cp.distance_to(content_position(event.position))
				if d > connection.line.rect_size.y * 2:
					continue
				if d < closest_d:
					closest = i
					closest_d = d

			if closest >= 0:
				hit_node = _connections[connection_list[closest].from][connection_list[closest].to].line

		match event.button_index:
			BUTTON_LEFT:
				if event.pressed:
					if not (hit_node in _selection) and not event.shift:
						clear_selection()

					if hit_node:
						_is_dragging_node = true
						select(hit_node)
						if hit_node is FlowChartLine:
							content_lines.move_child(hit_node, content_lines.get_child_count()-1) # Raise selected line to top
						if hit_node is FlowChartNode:
							content_nodes.move_child(hit_node, content_nodes.get_child_count()-1) # Raise selected node to top
							if event.shift:
								# Connection start
								_is_connecting = true
								_is_dragging_node = false
								var line = create_line_instance()
								var connection = Connection.new(line, hit_node, null)
								_connect_node(line, connection.get_from_pos(), connection.get_from_pos())
								_current_connection = connection
							accept_event()
					if not _is_dragging:
						# Drag start
						_is_dragging = true
						_drag_start_pos = event.position
						_drag_end_pos = event.position
				else:
					var was_connecting = _is_connecting
					var was_dragging_node = _is_dragging_node
					if _current_connection:
						if hit_node is FlowChartNode:
							# Connection end
							_disconnect_node(_current_connection.line)
							_current_connection.to_node = hit_node
							connect_node(_current_connection.from_node.name, _current_connection.to_node.name)
						else:
							_current_connection.line.queue_free()
						_is_connecting = false
						_current_connection = null
						accept_event()

					if _is_dragging:
						# Drag end
						_is_dragging = false
						_is_dragging_node = false
						if not (was_connecting or was_dragging_node):
							var selection_box_rect = get_selection_box_rect()
							# Select node
							for node in content_nodes.get_children():
								var rect = get_transform().xform(content.get_transform().xform(node.get_rect()))
								if selection_box_rect.intersects(rect):
									if node is FlowChartNode:
										select(node)
							# Select line
							var connection_list = get_connection_list()
							for i in connection_list.size():
								var connection = _connections[connection_list[i].from][connection_list[i].to]
								# Line's offset along its down-vector
								var line_local_up_offset = connection.line.rect_position - connection.line.get_transform().xform(Vector2.UP * connection.offset)
								var from_pos = content.get_transform().xform(connection.get_from_pos() + line_local_up_offset)
								var to_pos = content.get_transform().xform(connection.get_to_pos() + line_local_up_offset)
								if CohenSutherland.line_intersect_rectangle(from_pos, to_pos, selection_box_rect):
									select(connection.line)
						_drag_start_pos = _drag_end_pos
						update()

func get_selection_box_rect():
	var pos = Vector2(min(_drag_start_pos.x, _drag_end_pos.x), min(_drag_start_pos.y, _drag_end_pos.y))
	var size = (_drag_end_pos - _drag_start_pos).abs()
	return Rect2(pos, size)

func get_scroll_rect():
	var rect = Rect2()
	for child in content_nodes.get_children():
		var child_rect = child.get_rect()
		rect = rect.merge(child_rect)
	return rect.grow(scroll_margin)

func add_node(node):
	content_nodes.add_child(node)
	_on_node_added(node)

func remove_node(node_name):
	var node = content_nodes.get_node_or_null(node_name)
	if node:
		deselect(node) # Must deselct before remove to make sure _drag_origins synced with _selections
		content_nodes.remove_child(node)
		node.queue_free() # TODO: add to _to_free instead
		_on_node_removed(node_name)

func _on_node_added(node):
	pass

func _on_node_removed(node):
	pass

func _connect_node(line, from_pos, to_pos):
	content_lines.add_child(line)
	line.join(from_pos, to_pos)

func _disconnect_node(line):
	content_lines.remove_child(line)
	if line in _selection:
		deselect(line)
	line.queue_free()

func create_line_instance():
	return FlowChartLineScene.instance()

func rename_node(old, new):
	for from in _connections.keys():
		if from == old: # Connection from
			var from_connections = _connections[from]
			_connections.erase(old)
			_connections[new] = from_connections
		else: # Connection to
			for to in _connections[from].keys():
				if to == old:
					var from_connection = _connections[from]
					var value = from_connection[old]
					from_connection.erase(old)
					from_connection[new] = value

func connect_node(from, to):
	if from == to:
		return # Connect to self
	var connections_from = _connections.get(from)
	if connections_from:
		if to in connections_from:
			return # Connection existed
	var line = create_line_instance()
	var connection = Connection.new(line, content_nodes.get_node(from), content_nodes.get_node(to))
	if not connections_from:
		connections_from = {}
		_connections[from] = connections_from
	connections_from[to] = connection
	_connect_node(line, connection.get_from_pos(), connection.get_to_pos())

	# Check if connection in both ways
	connections_from = _connections.get(to)
	if connections_from:
		var inv_connection = connections_from.get(from)
		if inv_connection:
			connection.offset = interconnection_offset
			inv_connection.offset = interconnection_offset
			connection.join()
			inv_connection.join()
	_on_connect_node(from, to)
	emit_signal("connection", from, to, line)

func disconnect_node(from, to):
	var connections_from = _connections.get(from)
	var connection = connections_from.get(to)
	if not connection:
		return

	_disconnect_node(connection.line)
	if connections_from.size() == 1:
		_connections.erase(from)
	else:
		connections_from.erase(to)

	connections_from = _connections.get(to)
	if connections_from:
		var inv_connection = connections_from.get(from)
		if inv_connection:
			inv_connection.offset = 0
			inv_connection.join()
	_on_disconnect_node(from, to)
	emit_signal("disconnection", from, to)

func clear_connections():
	for connections_from in _connections.values():
		for connection in connections_from.values():
			connection.line.queue_free()
	_connections.clear()

func select(node):
	if node in _selection:
		return

	_selection.append(node)
	node.selected = true
	_drag_origins.append(node.rect_position)
	emit_signal("node_selected", node)

func deselect(node):
	_selection.erase(node)
	node.selected = false
	_drag_origins.pop_back()
	emit_signal("node_deselected", node)

func clear_selection():
	for node in _selection.duplicate(): # duplicate _selection array as deselect() edit array
		if not node:
			continue
		deselect(node)
	_selection.clear()

func duplicate_nodes(nodes):
	clear_selection()
	for i in nodes.size():
		var node = nodes[i]
		if not (node is FlowChartNode):
			continue
		var new_node = node.duplicate(DUPLICATE_SIGNALS + DUPLICATE_SCRIPTS)
		var offset = content_position(get_local_mouse_position()) - content_position(_drag_end_pos)
		new_node.rect_position = new_node.rect_position + offset
		add_node(new_node)
		select(new_node)

func _on_node_dragged(node, dragged):
	pass

func _on_connect_node(from, to):
	pass

func _on_disconnect_node(from, to):
	pass

# Convert position in FlowChart space to content(takes translation/scale of content into account)
func content_position(pos):
	return (pos - content.rect_position - content.rect_pivot_offset * (Vector2.ONE - content.rect_scale)) * 1.0/content.rect_scale

func get_connection_list():
	var connection_list = []
	for connections_from in _connections.values():
		for connection in connections_from.values():
			connection_list.append({"from": connection.from_node.name, "to": connection.to_node.name})
	return connection_list

class Connection:
	var line # Control node that draw line
	var from_node
	var to_node
	var offset = 0

	func _init(p_line, p_from_node, p_to_node):
		line = p_line
		from_node = p_from_node
		to_node = p_to_node

	func join():
		line.join(get_from_pos(), get_to_pos(), offset)

	func get_from_pos():
		return from_node.rect_position + from_node.rect_size / 2

	func get_to_pos():
		return to_node.rect_position + to_node.rect_size / 2 if to_node else line.rect_position