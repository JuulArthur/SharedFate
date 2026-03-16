extends TileMapLayer
@onready var obstacles_tilemap: TileMapLayer = $"../MyCustomObjects" 

func _ready():
	# Wait a frame to ensure all physics are loaded
	await get_tree().process_frame 
	update_navigation_obstacles()

func update_navigation_obstacles():
	# Get all cells used by the obstacles tilemap
	if (obstacles_tilemap):
		var used_obstacle_cells = obstacles_tilemap.get_used_cells()

		#for cell_coords in used_obstacle_cells:
			# Convert obstacle cell coordinates to the local coordinates of the navigation tilemap
			# The coordinates should already be in the same grid space if tilemaps share the same cell size and position

			# Remove the navigation polygon for the cell at these coordinates in the navigation tilemap
			# The 0 is the navigation layer ID (index) in the TileSet
		#	set_cell(cell_coords, -1, Vector2i(-1, -1), -1) # Set to invalid source id/atlas coords to remove the tile and its nav data
