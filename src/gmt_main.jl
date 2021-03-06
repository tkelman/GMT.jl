global API			# OK, so next times we'll use this one

type GMTJL_GRID 	# The type holding a local header and data of a GMT grid
	ProjectionRefPROJ4::ASCIIString
	ProjectionRefWKT::ASCIIString
	range::Array{Float64,1}
	inc::Array{Float64,1}
	n_rows::Int
	n_columns::Int
	n_bands::Int
	registration::Int
	NoDataValue::Float64
	title::ASCIIString
	remark::ASCIIString
	command::ASCIIString
	DataType::ASCIIString
	x::Array{Float64,1}
	y::Array{Float64,1}
	z::Array{Float32,2}
	x_units::ASCIIString
	y_units::ASCIIString
	z_units::ASCIIString
end

type GMTJL_IMAGE 	# The type holding a local header and data of a GMT image
	ProjectionRefPROJ4::ASCIIString
	ProjectionRefWKT::ASCIIString
	range::Array{Float64,1}
	inc::Array{Float64,1}
	n_rows::Int
	n_columns::Int
	n_bands::Int
	registration::Int
	NoDataValue::Float64
	title::ASCIIString
	remark::ASCIIString
	command::ASCIIString
	DataType::ASCIIString
	x::Array{Float64,1}
	y::Array{Float64,1}
	image::Array{UInt8,3}
	x_units::ASCIIString
	y_units::ASCIIString
	z_units::ASCIIString
	colormap::Array{Clong,1}
	nColors::Int
	alpha::Array{UInt8,2}
end

type GMTJL_CPT
	colormap::Array{Float64,2}
	alpha::Array{Float64,1}
	range::Array{Float64,2}
	rangeMinMax::Array{Float64,1}
end

type GMTJL_PS
	ps::UTF8String		# Actual PS text
	mode::Int 			# 1 = Has header, 2 = Has trailer, 3 = Has both
end

# Container to hold info to allow creating grids in a simple (but limmited) maner
type array_container
	nx::Int
	ny::Int
	n_bands::Int
	grd::Ptr{Float32}
	hdr::Ptr{Float64}
end

"""
Call a GMT module. Usage:

    gmt("module_name `options`")

Example. To plot a simple map of Iberia in the postscript file nammed `lixo.ps` do:

    gmt("pscoast -R-10/0/35/45 -B1 -W1 -Gbrown -JM14c -P -V > lixo.ps")
"""
function gmt(cmd::ASCIIString, args...)
	global API
	
	# ----------- Minimal error checking ------------------------
	if (~isa(cmd, ASCIIString))
		error("gmt: first argument must always be a string")
	end
	n_argin = length(args)
	# -----------------------------------------------------------

	try
		a = API
		if (!isa(API, Ptr{Void}))
			error("The 'API' is not a Ptr{Void}. Creating a new one.")
		end
	catch
		API = GMT_Create_Session("GMT", 2, GMT.GMT_SESSION_NOEXIT + GMT.GMT_SESSION_EXTERNAL
		                         + GMT.GMT_SESSION_COLMAJOR)
		if (API == C_NULL)
			error("Failure to create a GMT5 Session")
		end
	end

	# 1. Get arguments, if any, and extract the GMT module name
	# First argument is the command string, e.g., "blockmean -R0/5/0/5 -I1" or just "help"
	g_module, r = strtok(cmd)

	# 2. In case this was a clean up call
	if (g_module == "destroy")
		if (GMT_Destroy_Session(API) != 0)
			error("GMT: Failure to destroy GMT5 session")
		end
		API = NaN
		return
	end

	# 2+ Add -F to psconvert if user requested a return image but did not give -F
	if (g_module == "psconvert" && n_argin == 0 && (isempty(r) || isempty(search(r, "-F"))))
		if (!isempty(r))
			r = r * " -F"
		else
			r = "-F"
		end
	end

	# 3. Convert command line arguments to a linked GMT option list
	LL = GMT_Create_Options(API, 0, r)	# It uses also the fact that GMT parses and check options
	if (LL == C_NULL)
		error("Error creating the linked list of options. Probably a bad usage.")
	end

	# 4. Preprocess to update GMT option lists and return info array X
	n_items = pointer([0])
	pLL = Ref([LL])
	if ((X = GMT_Encode_Options(API, g_module, '$', n_argin, pLL, n_items)) == C_NULL)	# This call also changes LL
		# Get the pointees
		n_items = unsafe_load(n_items)
		if (n_items > 65000)				# Just got usage/synopsis option (if (n_items == UINT_MAX)) in C
			n_items = 0
		else
			error("GMT: Failure to encode Julia command options")
		end
	else
		n_items = unsafe_load(n_items)
	end

	#X = pointer_to_array(X,n_items)     # The array of GMT_RESOURCE structs
	XX = Array(GMT_RESOURCE, 1, n_items)
	for (k = 1:n_items)
		XX[k] = unsafe_load(X, k)        # Cannot use pointer_to_array() because GMT_RESOURCE is not immutable and would BOOM!
	end
	X = XX

	# 5. Assign input (from julia) and output (from GMT) resources
	name_PS = ""
	for (k = 1:n_items)                 # Number of GMT containers involved in this module call */
		if (X[k].direction == GMT_IN && n_argin == 0)
			error("GMT: Expected a Matrix for input")
		end
		ptr = (X[k].direction == GMT_IN) ? args[X[k].pos+1] : []
		X[k].object, X[k].object_ID = GMTJL_register_IO(API, X[k], ptr)
		#out, X[k].object = GMTJL_register_IO(API, X[k], ptr)
		#return X[k].object
		if (X[k].object == C_NULL || X[k].object_ID == GMT.GMT_NOTSET)
			error("GMT: Failure to register the resource\n")
		end
		name = "                "
		if (GMT_Encode_ID(API, name, X[k].object_ID) != GMT.GMT_NOERROR)        # Make filename with embedded object ID */
			error("GMT: Failure to encode string")
		end
		if (GMT_Expand_Option(API, X[k].option, '$', name) != GMT.GMT_NOERROR)  # Replace ARG_MARKER in argument with name */
			error("GMT: Failure to expand filename marker")
		end
		if (X[k].family == GMT_IS_PS)
			name_PS = name
		end
	end

	# 6. Run GMT module; give usage message if errors arise during parsing
	status = GMT_Call_Module(API, g_module, GMT_MODULE_OPT, LL)
	if (!(status == GMT_NOERROR || status == GMT_SYNOPSIS))
		error("Something went wrong when calling the module. GMT error number = ", status)
	end

	# 7. Hook up module GMT outputs to Julia array
	# But first cout the number of outputs
	n_out = 0
	for (k = 1:n_items)                     # Number of GMT containers involved in this module call
		if (X[k].direction == GMT_IN) continue 	end
		n_out = n_out + 1
	end
	out = []
	if (n_out > 0)
		out = cell(n_out)
	end

	for (k = 1:n_items)                     # Number of GMT containers involved in this module call
		if (X[k].direction == GMT_IN) continue 	end      # ONly looking for stuff coming OUT of GMT here
		if ((X[k].object = GMT_Retrieve_Data(API, X[k].object_ID)) == C_NULL)
			error("GMT: Error retrieving object from GMT")
		end
		pos = X[k].pos + 1                      # Short-hand for index into the plhs[] array being returned to Julia
		if (X[k].family == GMT_IS_GRID)         # Determine what container we got
			out[pos] = get_grid(API, X[k].object)
		elseif (X[k].family == GMT_IS_DATASET)  # A GMT table; make it a matrix and the pos'th output item
			out[pos] = get_table(API, X[k].object)
		elseif (X[k].family == GMT_IS_TEXTSET)  # A GMT textset; make it a cell and the pos'th output item
			out[pos] = get_textset(API, X[k].object)
		elseif (X[k].family == GMT_IS_CPT)      # A GMT CPT; make it a colormap and the pos'th output item
			out[pos] = get_cpt(API, X[k].object)
		elseif (X[k].family == GMT_IS_IMAGE)    # A GMT Image; make it the pos'th output item
			out[pos] = get_image(API, X[k].object)
		elseif (X[k].family == GMT_IS_PS)       # A PostScrip structure
			out[pos] = get_PS(API, X[k].object)
#			status = GMT_Call_Module(API, "psconvert", GMT_MODULE_CMD, "# -A -Tg")
#			status = GMT_Call_Module(API, "psconvert", GMT_MODULE_CMD, name_PS * " -A -Tf")
		end
	end

	# 8. Free all GMT containers involved in this module call
	for (k = 1:n_items) 
		#if (X[k].family != GMT_IS_TEXTSET) 		# Gave up. The GMT_IS_TEXTSET will have to leak (blame the immutables)
			ppp = X[k].object
			if (GMT_Destroy_Data(API, Ref([X[k].object])) != GMT.GMT_NOERROR)
				error("GMT: Failed to destroy object used in the interface bewteen GMT and Julia")
			else 	# Success, now make sure we dont destroy the same pointer more than once
				for (kk = k+1:n_items)
					if (X[kk].object == ppp) 	X[kk].object = C_NULL;		end
				end
			end
		#end
	end

	# 9. Destroy linked option list
	if (GMT_Destroy_Options(API, pLL) != 0)
		error("GMT: Failure to destroy GMT5 options")
	end

	# Return a variable number of outputs but don't think we even can return 3
	if (n_out == 0)
		return []
	elseif (n_out == 1)
		return out[1]
	elseif (n_out == 2)
		return out[1], out[2]
	elseif (n_out == 3)
		return out[1], out[2], out[3]
	else
		println("Case non-foreseen. More than 3 outputs?")
		return out
	end

end

# ---------------------------------------------------------------------------------------------------
function create_cmd(LL)
	# Takes a LinkedList LL of gmt options created by GMT_Create_Options() and join them in a single
	# string but taking care that all options start with the '-' char and insert '<' if necessary
	# For example "-Tg lixo.grd" will become "-Tg -<lixo.grd"
	LL_up = unsafe_load(LL);
	done = false
	a = IOBuffer()
	while (!done)
		print(a, '-', char(LL_up.option))
		print(a, bytestring(LL_up.arg))
		if (LL_up.next != C_NULL)
			print(a, " ")
			LL_up = unsafe_load(LL_up.next);
		else
			done = true
		end
	end
	return takebuf_string(a)
end

# ---------------------------------------------------------------------------------------------------
function strtok(args, delim::ASCIIString=" ")
# A Matlab like strtok function
	tok = "";	r = ""
	if (~isvalid(args))
		return tok, r
	end

	ind = search(args, delim)
	if (isempty(ind))
		return lstrip(args,collect(delim)), r		# Always clip delimiters at the begining
	end
	tok = lstrip(args[1:ind[1]-1], collect(delim))	#		""
	r = lstrip(args[ind[1]:end], collect(delim))

	return tok,r
end

# ---------------------------------------------------------------------------------------------------
function GMT_IJP(hdr::GMT_GRID_HEADER, row, col)
# Function for indecing into a GMT grid [with pad]
# padTop (hdr.pad[GMT.GMT_YHI]) and padLeft (hdr.pad[GMT.GMT_XLO]) are normally equal
	#ij = (row + hdr.pad[4]) * hdr.mx + col + hdr.pad[1]		# in C
	ij = ((row-1) + hdr.pad[4]) * hdr.mx + col + hdr.pad[1]
end

# ---------------------------------------------------------------------------------------------------
function GMT_IJP(row::Integer, col, mx, padTop, padLeft)
# Function for indecing into a GMT grid [with pad]
# padTop (hdr.pad[GMT.GMT_YHI]) and padLeft (hdr.pad[GMT.GMT_XLO]) are normally equal
	#ij = (row + padTop) * mx + col + padLeft		# in C
	ij = ((row-1) + padTop) * mx + col + padLeft
end

# ---------------------------------------------------------------------------------------------------
function MEXG_IJ(row, col, ny)
	# Get the ij that correspond to (row,col) [no pad involved]
	#ij = col * ny + ny - row - 1		in C
	ij = col * ny - row + 1
end

# ---------------------------------------------------------------------------------------------------
function get_grid(API, object)
# ...
	G = unsafe_load(convert(Ptr{GMT_GRID}, object))
	if (G.data == C_NULL)
		error("get_grid: programming error, output matrix is empty")
	end

	gmt_hdr = unsafe_load(G.header)
	ny = Int(gmt_hdr.ny);		nx = Int(gmt_hdr.nx);		nz = Int(gmt_hdr.n_bands)
	padTop = Int(gmt_hdr.pad[4]);	padLeft = Int(gmt_hdr.pad[1]);
	mx = Int(gmt_hdr.mx);		my = Int(gmt_hdr.my)
	X  = linspace(gmt_hdr.wesn[1], gmt_hdr.wesn[2], nx)
	Y  = linspace(gmt_hdr.wesn[3], gmt_hdr.wesn[4], ny)

	#API = unsafe_load(convert(Ptr{GMTAPI_CTRL}, API))	# Get access to a minimalist API struct (no API.GMT)
	t   = pointer_to_array(G.data, my * mx)
	z   = zeros(Float32, ny, nx)

	for (col = 1:nx)
		for (row = 1:ny)
			#ij = GMT_IJP(gmt_hdr, row, col)
			ij = GMT_IJP(row, col, mx, padTop, padLeft)		# This one is Int64
			z[MEXG_IJ(row, col, ny)] = t[ij]	# Later, replace MEXG_IJ() by kk = col * ny - row + 1
		end
	end

	#t  = reshape(pointer_to_array(G.data, ny * nx), ny, nx)

	# Return grids via a float matrix in a struct
	out = GMTJL_GRID("", "", zeros(6)*NaN, zeros(2)*NaN, 0, 0, 0, 0, NaN, "", "", "", "", X, Y, z, "", "", "")

	if (gmt_hdr.ProjRefPROJ4 != C_NULL)
		out.ProjectionRefPROJ4 = bytestring(gmt_hdr.ProjRefPROJ4)
	end
	if (gmt_hdr.ProjRefWKT != C_NULL)
		out.ProjectionRefWKT = bytestring(gmt_hdr.ProjectionRefWKT)
	end

	# The following is uggly is a consequence of the clag.jl translation of fixed sixe arrays  
	out.range = vec([gmt_hdr.wesn[1] gmt_hdr.wesn[2] gmt_hdr.wesn[3] gmt_hdr.wesn[4] gmt_hdr.z_min gmt_hdr.z_max])
	out.inc          = vec([gmt_hdr.inc[1] gmt_hdr.inc[2]])
	out.n_rows       = ny
	out.n_columns    = nx
	out.NoDataValue  = gmt_hdr.nan_value
	out.registration = gmt_hdr.registration
	out.n_bands      = gmt_hdr.n_bands
	out.x_units      = bytestring(UInt8[gmt_hdr.x_units...])
	out.y_units      = bytestring(UInt8[gmt_hdr.y_units...])
	out.z_units      = bytestring(UInt8[gmt_hdr.z_units...])

	return out
end

# ---------------------------------------------------------------------------------------------------
function get_image(API, object)
# ...
	I = unsafe_load(convert(Ptr{GMT_IMAGE}, object))
	if (I.data == C_NULL)
		error("get_image: programming error, output matrix is empty")
	end

	gmt_hdr = unsafe_load(I.header)
	ny = Int(gmt_hdr.ny);		nx = Int(gmt_hdr.nx);		nz = Int(gmt_hdr.n_bands)
	X  = linspace(gmt_hdr.wesn[1], gmt_hdr.wesn[2], nx)
	Y  = linspace(gmt_hdr.wesn[3], gmt_hdr.wesn[4], ny)
	t  = reshape(pointer_to_array(I.data, ny * nx * nz), ny, nx, nz)

	if (I.ColorMap != C_NULL)       # Indexed image has a color map (PROBABLY NEEDS TRANSPOSITION)
		nColors = Int64(I.nIndexedColors)
		colormap = pointer_to_array(I.ColorMap, nColors * 4)
		#colormap = reshape(colormap, 4, nColors)'
	else
		colormap = vec(zeros(Clong,1,3))	# Because we need an array
		nColors = 0
	end

	# Return grids via a float matrix in a struct
	if (gmt_hdr.n_bands <= 3)
		out = GMTJL_IMAGE("", "", zeros(6)*NaN, zeros(2)*NaN, 0, 0, 0, 0, NaN, "", "", "", "", X, Y,
	                      t, "", "", "", colormap, nColors, zeros(UInt8,ny,nx)) 	# <== Ver o qur fazer com o alpha
	else 			# RGB(A) image
		out = GMTJL_IMAGE("", "", zeros(6)*NaN, zeros(2)*NaN, 0, 0, 0, 0, NaN, "", "", "", "", X, Y,
	                      t[:,:,1:3], "", "", "", colormap, nColors, t[:,:,4])
	end

	if (gmt_hdr.ProjRefPROJ4 != C_NULL)
		out.ProjectionRefPROJ4 = bytestring(gmt_hdr.ProjRefPROJ4)
	end
	if (gmt_hdr.ProjRefWKT != C_NULL)
		out.ProjectionRefWKT = bytestring(gmt_hdr.ProjectionRefWKT)
	end

	# The following is uggly is a consequence of the clag.jl translation of fixed sixe arrays  
	out.range = vec([gmt_hdr.wesn[1] gmt_hdr.wesn[2] gmt_hdr.wesn[3] gmt_hdr.wesn[4] gmt_hdr.z_min gmt_hdr.z_max])
	out.inc          = vec([gmt_hdr.inc[1] gmt_hdr.inc[2]])
	out.n_rows       = ny
	out.n_columns    = nx
	out.NoDataValue  = gmt_hdr.nan_value
	out.registration = gmt_hdr.registration
	out.n_bands      = gmt_hdr.n_bands

	return out
end

# ---------------------------------------------------------------------------------------------------
function get_cpt(API, object::Ptr{Void})
# Hook this Julia CPT into the k'th output item

	C = unsafe_load(convert(Ptr{GMT_PALETTE}, object))

	if (C.range == C_NULL)
		error("get_cpt: programming error, output CPT is empty")
	end

	n_colors = (C.is_continuous != 0) ? C.n_colors + 1 : C.n_colors
	out = GMTJL_CPT(zeros(n_colors, 3), zeros(n_colors), zeros(C.n_colors, 2), zeros(2)*NaN)

	for (j = 1:C.n_colors)       # Copy r/g/b from palette to Julia array
		gmt_lut = unsafe_load(C.range, j)
		out.colormap[j, 1] = gmt_lut.rgb_low[1]
		out.colormap[j, 2] = gmt_lut.rgb_low[2]
		out.colormap[j, 3] = gmt_lut.rgb_low[3]
		out.range[j, 1]    = gmt_lut.z_low
		out.range[j, 2]    = gmt_lut.z_high
		out.alpha[j] = gmt_lut.rgb_low[4]
	end
	if (C.is_continuous != 0)    # Add last color
		out.colormap[n_colors, 1] = gmt_lut.rgb_high[1]
		out.colormap[n_colors, 2] = gmt_lut.rgb_high[2]
		out.colormap[n_colors, 3] = gmt_lut.rgb_high[3]
	end
	gmt_lut = unsafe_load(C.range, 1)
	out.rangeMinMax[1] = gmt_lut.z_low
	gmt_lut = unsafe_load(C.range, C.n_colors)
	out.rangeMinMax[2] = gmt_lut.z_high

	return out
end

# ---------------------------------------------------------------------------------------------------
function get_textset(API, object::Ptr{Void})
	# Hook this Julia TEXTSET into the k'th output item
	
	if (object == C_NULL)
		error("get_cpt: programming error, output textset is NULL")
	end

	T = unsafe_load(convert(Ptr{GMT_TEXTSET}, object))
	p = pointer_to_array(pointer_to_array(T.table,1)[1],1) 		# T.table::Ptr{Ptr{GMT.GMT_TEXTTABLE}}

	# Create a cell array to hold all records
	k = T.n_records
	if (p[1].n_segments > 1) k += p[1].n_segments	end
	C = cell(k)
	# There is only one table when used in the external API, but it may have many segments.
	# The segment information is lost when returned to Julia

	k = 0
	for (seg = 1:p[1].n_segments)
		S = pointer_to_array(pointer_to_array(p[1].segment,1)[seg],seg)	# p[1].segment::Ptr{Ptr{GMT.GMT_TEXTSEGMENT}}
		if (p[1].n_segments > 1)
			C[k] = @sprintf("> %s", bytestring(S[1].header))
			k += 1 
		end
		for (row = 1:S[1].n_rows)
			k += 1
			C[k] = bytestring(pointer_to_array(S[1].record, row)[row])
		end
	end

	return C
end

# ---------------------------------------------------------------------------------------------------
function get_PS(API, object::Ptr{Void})
	# Given a GMT Postscript structure P, build a Julia PS type
	
	if (object == C_NULL)
		error("get_cpt: programming error, output textset is NULL")
	end

	P = unsafe_load(convert(Ptr{GMT_PS}, object))
	out = GMTJL_PS(bytestring(P.data), Int(P.n))

	return out
end

# ---------------------------------------------------------------------------------------------------
function get_table(API, object)
# ...
	M = unsafe_load(convert(Ptr{GMT_VECTOR}, object))
	if (M.data == C_NULL)
		error("get_table: programming error, output matrix is empty")
	end

	tipo = GMTJL_type(API)
	if (tipo == DOUBLE_CLASS)
		out = zeros(Float64, M.n_rows, M.n_columns)
		t = pointer_to_array(convert(Ptr{Ptr{Cdouble}},M.data), M.n_columns)
	elseif (tipo == SINGLE_CLASS)
		out = zeros(Float32, M.n_rows, M.n_columns)
		t = pointer_to_array(convert(Ptr{Ptr{Cfloat}},M.data), M.n_columns)
	elseif (tipo == UINT64_CLASS)
		out = zeros(Culonglong, M.n_rows, M.n_columns)
		t = pointer_to_array(convert(Ptr{Ptr{Culonglong}},M.data), M.n_columns)
	elseif (tipo == INT64_CLASS)
		out = zeros(Clonglong, M.n_rows, M.n_columns)
		t = pointer_to_array(convert(Ptr{Ptr{Clonglong}},M.data), M.n_columns)
	elseif (tipo == UINT32_CLASS)
		out = zeros(Cuint, M.n_rows, M.n_columns)
		t = pointer_to_array(convert(Ptr{Ptr{Cuint}},M.data), M.n_columns)
	elseif (tipo == INT32_CLASS)
		out = zeros(Cint, M.n_rows, M.n_columns)
		t = pointer_to_array(convert(Ptr{Ptr{Cint}},M.data), M.n_columns)
	elseif (tipo == UINT16_CLASS)
		out = zeros(Cushort, M.n_rows, M.n_columns)
		t = pointer_to_array(convert(Ptr{Ptr{Cushort}},M.data), M.n_columns)
	elseif (tipo == INT16_CLASS)
		out = zeros(Cshort, M.n_rows, M.n_columns)
		t = pointer_to_array(convert(Ptr{Ptr{Cshort}},M.data), M.n_columns)
	elseif (tipo == UINT8_CLASS)
		out = zeros(Cuchar, M.n_rows, M.n_columns)
		t = pointer_to_array(convert(Ptr{Ptr{Cuchar}},M.data), M.n_columns)
	elseif (tipo == INT8_CLASS)
		out = zeros(Cchar, M.n_rows, M.n_columns)
		t = pointer_to_array(convert(Ptr{Ptr{Cchar}},M.data), M.n_columns)
	else
		error("get_table: Unsupported data type in GMT matrix input.")
	end

	for (c = 1:M.n_columns)
		tt = pointer_to_array(t[c], M.n_rows)
		for (r = 1:M.n_rows)
			out[r, c] = tt[r]
		end
	end

#=
	out = zeros(Float64, M.n_rows, M.n_columns)
	if (M.shape == GMT.GMT_IS_COL_FORMAT)  # Easy, just copy
		out = copy!(out, t)
	else	# Must transpose
		for (col = 1:M.n_columns)
			for (row = 1:M.n_rows)
				#ij = (row - 1) * M.n_columns + col
				ij = (col - 1) * M.n_rows + col
				out[row, col] = t[ij]
			end
		end
	end
=#

	return out
end

# ---------------------------------------------------------------------------------------------------
function GMTJL_register_IO(API::Ptr{Void}, X::GMT_RESOURCE, ptr)
# Create the grid or matrix contains, register them, and return the ID
	oo = unsafe_load(X.option)
	module_input = (oo.option == GMT.GMT_OPT_INFILE)
	ID = GMT.GMT_NOTSET
	if (X.family == GMT_IS_GRID)
		# Get an empty grid, and if input associate it with the Julia grid pointer
		obj = GMTJL_grid_init(API, module_input, ptr, X.direction)
		ID  = GMT_Get_ID(API, GMT_IS_GRID, X.direction, obj)
	elseif (X.family == GMT_IS_IMAGE)
		obj = GMTJL_image_init(API, module_input, ptr, X.direction)
		ID  = GMT_Get_ID(API, GMT_IS_IMAGE, X.direction, obj)
	elseif (X.family == GMT_IS_DATASET)
		# Ostensibly a DATASET, but it might be a TEXTSET passed via a cell array, so we must check
		if (X.direction == GMT_IN && ((eltype(ptr) == Array{Any}) || (eltype(ptr) == ASCIIString)))		# Got TEXTSET input
			obj = GMTJL_Text_init(API, module_input, ptr, X.direction, GMT_IS_TEXTSET)
		else 		# Get a matrix container, and if input we associate it with the Julia pointer
			obj = GMTJL_dataset_init(API, module_input, ptr, X.direction)
		end
		ID  = GMT_Get_ID(API, GMT_IS_DATASET, X.direction, obj)
	elseif (X.family == GMT_IS_CPT)
		# Get a CPT container, and if input associate it with the Julia CPT pointer
		obj = GMTJL_CPT_init(API, module_input, ptr, X.direction)
		ID  = GMT_Get_ID(API, GMT_IS_CPT, X.direction, obj)
	elseif (X.family == GMT_IS_TEXTSET)
		# Get a TEXTSET container, and if input associate it with the Julia pointer
		obj = GMTJL_Text_init(API, module_input, ptr, X.direction, GMT_IS_TEXTSET)
		ID  = GMT_Get_ID(API, GMT_IS_TEXTSET, X.direction, obj)
	elseif (X.family == GMT_IS_PS)
		obj = GMTJL_PS_init(API, module_input, ptr, X.direction)
		ID  = GMT_Get_ID(API, GMT_IS_PS, X.direction, obj)
	else
		error("GMTJL_register_IO: Bad data type ", X.family)
	end
	return obj, ID
end

# ---------------------------------------------------------------------------------------------------
function GMTJL_grid_init(API::Ptr{Void}, module_input, grd_box, dir::Integer=GMT_IN)
# If GRD_BOX is empty just allocate (GMT) an empty container and return
# If GRD_BOX is not empty it must contain either a array_container or a GMTJL_GRID type.

	empty = false 		# F... F... it's a shame having to do this
	try
		isempty(grd_box)
		empty = true
	end

	if (empty)			# Just tell GMTJL_grid_init() to allocate an empty container 
		if ((R = GMT_Create_Data(API, GMT_IS_GRID, GMT_IS_SURFACE, GMT_GRID_HEADER_ONLY, 
		                         C_NULL, C_NULL, C_NULL, 0, 0, C_NULL)) == C_NULL)
			error("grid_init: Failure to alloc GMT blank grid container for holding output grid")
		end
		return R
	end

	if (isa(grd_box, array_container))
		grd = pointer_to_array(grd_box.grd, (grd_box.ny, grd_box.nx))
		hdr = pointer_to_array(grd_box.hdr, 9)
		R = GMTJL_grid_init(API, module_input, [], grd, hdr)
	elseif (isa(grd_box, GMTJL_GRID))
		R = GMTJL_grid_init(API, module_input, grd_box, [], [])
	else
		error(@sprintf("GMTJL_PARSER:grd_init: input (%s) is not a GRID|IMAGE container type", typeof(grd_box)))
	end
	return R
end

# ---------------------------------------------------------------------------------------------------
function GMTJL_grid_init(API::Ptr{Void}, module_input, Grid, grd, hdr, pad::Int=2)
# We are given a Julia grid and can determine its size, etc.

	if (isa(Grid, GMTJL_GRID))
		grd = Grid.z
		hdr = [Grid.range; Grid.registration; Grid.inc]
	end
	if ((G = GMT_Create_Data(API, GMT_IS_GRID, GMT_IS_SURFACE, GMT_GRID_HEADER_ONLY, C_NULL,
	                         hdr[1:4], hdr[8:9], UInt32(hdr[7]), pad)) == C_NULL)
		error("grid_init: Failure to alloc GMT source matrix for input")
	end

	n_rows = size(grd, 1);		n_cols = size(grd, 2);		mx = n_cols + 2*pad;
	t = zeros(Float32, n_rows+2*pad, n_cols+2*pad)

	for (col = 1:n_cols)
		for (row = 1:n_rows)
			ij = GMT_IJP(row, col, mx, pad, pad)
			t[ij] = grd[MEXG_IJ(row, col, n_rows)]	# Later, replace MEXG_IJ() by kk = col * ny - row + 1
		end
	end

	Gb = unsafe_load(G)			# Gb = GMT_GRID (constructor with 1 method)
	Gb.data = pointer(t)
	Gb.alloc_mode = UInt32(GMT.GMT_ALLOCATED_EXTERNALLY)	# Since array was allocated by Julia
	h = unsafe_load(Gb.header)
	h.z_min = hdr[5]			# Set the z_min, z_max
	h.z_max = hdr[6]

	if (isa(Grid, GMTJL_GRID))
		h.x_units = map(UInt8, (Grid.x_units...))
		h.y_units = map(UInt8, (Grid.y_units...))
		h.z_units = map(UInt8, (Grid.z_units...))
	end

	unsafe_store!(Gb.header, h)
	unsafe_store!(G, Gb)
	GMT_Report(API, GMT.GMT_MSG_DEBUG, @sprintf("Allocate GMT Grid %s in parser\n", G) )

	return G
end

# ---------------------------------------------------------------------------------------------------
function GMTJL_image_init(API::Ptr{Void}, module_input, img_box, dir::Integer=GMT_IN)
	# ...

	if (isempty(img_box))		# Just tell GMTJL_image_init() to allocate an empty container 
		R = GMTJL_image_init(API, module_input, [0.0], [0.0 0 0 0 0 0 0 0 0], dir)
		return R
	end

	if (isa(img_box, array_container))
		img = pointer_to_array(img_box.grd, (img_box.ny, img_box.nx, img_box.n_bands))
		hdr = pointer_to_array(img_box.hdr, 9)
	elseif (isa(img_box, GMTJL_IMAGE))
		img = img_box.image
		hdr = [img_box.range; img_box.registration; img_box.inc]
	else
		error("GMTJL_PARSER:image_init: input is not a GRID|IMAGE container type")
	end
	R = GMTJL_image_init(API, module_input, img, hdr, dir)
	return R
end

# ---------------------------------------------------------------------------------------------------
function GMTJL_image_init(API::Ptr{Void}, module_input, img, hdr::Array{Float64}, dir::Integer=GMT_IN, pad::Int=0)
# ...

	if (dir == GMT_IN)
		if ((I = GMT_Create_Data(API, GMT_IS_IMAGE, GMT_IS_SURFACE, GMT_GRID_ALL, C_NULL,
		                         hdr[1:4], hdr[8:9], UInt32(hdr[7]), pad)) == C_NULL)
			error("image_init: Failure to alloc GMT source image for input")
		end
		n_rows = size(img, 1);		n_cols = size(img, 2);		n_pages = size(img, 3)
		t = zeros(UInt32, n_rows, n_cols, n_pages)

		for (col = 1:n_cols)
			ic = col * n_rows
			for (row = 1:n_rows)
				ij = ic - row + 1
				t[row, col] = grd[ij]
			end
		end

		Ib = unsafe_load(I)			# Ib = GMT_IMAGE (constructor with 1 method)
		Ib.data = pointer(t)
		Ib.alloc_mode = UInt32(GMT.GMT_ALLOCATED_EXTERNALLY)	# Since array was allocated by Julia
		h = unsafe_load(Ib.header)
		h.z_min = hdr[5]			# Set the z_min, z_max
		h.z_max = hdr[6]
		unsafe_store!(Ib.header, h)
		unsafe_store!(I, Ib)
		GMT_Report(API, GMT.GMT_MSG_DEBUG, @sprintf("Allocate GMT Image %s in parser\n", I) )
	else	# Just allocate an empty container to hold the output grid, and pass GMT_VIA_OUTPUT
		if ((I = GMT_Create_Data(API, GMT_IS_IMAGE, GMT_IS_SURFACE, GMT_GRID_HEADER_ONLY, 
		                          C_NULL, C_NULL, C_NULL, 0, 0, C_NULL)) == C_NULL)
			error("image_init: Failure to alloc GMT blank grid container for holding output grid")
		end
		GMT_Set_Default(API, "API_IMAGE_LAYOUT", "BRLS");	# State how we wish to receive images from GDAL
	end
	return I

end

# ---------------------------------------------------------------------------------------------------
function GMTJL_matrix_init(API::Ptr{Void}, module_input, grd, dir::Integer=GMT_IN, pad::Int=0)
# ...
	if (dir == GMT_IN)
		dim = pointer([size(grd,2), size(grd,1), 0])	# MATRIX in GMT uses (col,row)
		mode = 0;
	else
		dim = C_NULL
		mode = GMT_VIA_OUTPUT;
	end

	if ((M = GMT_Create_Data(API, GMT_IS_MATRIX, GMT_IS_PLP, mode, dim, C_NULL, C_NULL, 0, 0, C_NULL)) == C_NULL)
		println("GMTJL_PARSER:matrix_init: Failure to alloc GMT source matrix")
		return -1
	end

	GMT_Report(API, GMT.GMT_MSG_DEBUG, @sprintf("Allocate GMT Matrix %s in gmtjl_parser\n", M) )
	Mb = unsafe_load(M)			# Mb = GMT_MATRIX (constructor with 1 method)
	Mb.n_rows    = size(grd,1)
	Mb.n_columns = size(grd,2)

	if (dir == GMT_IN)
		# NEED TO ADD CODE FOR THE OTHER DATA TYPES
		if (eltype(grd) == Float64)
			Mb._type = UInt32(GMT.GMT_DOUBLE)
		elseif (eltype(grd) == Float32)
			Mb._type = UInt32(GMT.GMT_FLOAT)
		else
			error("GMTJL_matrix_init: only floating point types allowed in input. Others need to be added")
		end
		Mb.data  = pointer(grd)
		Mb.dim = Mb.n_rows		# Data from Julia is in column major
		Mb.alloc_mode = GMT.GMT_ALLOC_EXTERNALLY;	# Since matrix was allocated by Julia
		Mb.shape = GMT.GMT_IS_COL_FORMAT;		# Julia order is column major */

	else
		Mb._type = UInt32(GMT.GMT_FLOAT)		# PROVIDE A MEAN TO CHOOSE?
		if (~isempty(grd))
			Mb.data  = pointer(grd)
		end
		# Data from GMT must be in row format since we may not know n_rows until later
		Mb.shape = UInt32(GMT.GMT_IS_ROW_FORMAT)
	end

	unsafe_store!(M, Mb)
	return M
end

# ---------------------------------------------------------------------------------------------------
function GMTJL_dataset_init(API::Ptr{Void}, module_input, ptr, direction::Integer)
# Used to create containers to hold or receive data:
# direction == GMT_IN:  Create empty Matrix container, associate it with mex data matrix, and use as GMT input.
# direction == GMT_OUT: Create empty Vector container, let GMT fill it out, and use for Mex output.
# Note that in GMT these will be considered DATASETs via GMT_MATRIX or GMT_VECTOR.
# If direction is GMT_IN then we are given a Julia matrix and can determine size, etc.
# If output then we dont know size so all we do is specify data type.

	if (direction == GMT_IN) 	# Dimensions are known, extract them and set dim array for a GMT_MATRIX resource */
		dim = pointer([size(ptr,2), size(ptr,1), 0])	# MATRIX in GMT uses (col,row)
		#if (!mxIsNumeric (ptr)) error("GMTJL_dataset_init: Expected a Matrix for input\n");
		if ((M = GMT_Create_Data(API, GMT_IS_MATRIX, GMT_IS_PLP, 0, dim, C_NULL, C_NULL, 0, 0, C_NULL)) == C_NULL)
			error("GMTJL_dataset_init: Failure to alloc GMT source matrix")
		end

		GMT_Report(API, GMT.GMT_MSG_DEBUG, @sprintf("Allocate GMT Matrix %s in gmtjl_parser\n", M) )
		Mb = unsafe_load(M)			# Mb = GMT_MATRIX (constructor with 1 method)
		tipo = get_datatype(ptr)
		Mb.n_rows    = size(ptr,1)
		Mb.n_columns = size(ptr,2)

		if (eltype(ptr)     == Float64)		Mb._type = UInt32(GMT.GMT_DOUBLE)
		elseif (eltype(ptr) == Float32)		Mb._type = UInt32(GMT.GMT_FLOAT)
		elseif (eltype(ptr) == UInt64)		Mb._type = UInt32(GMT.GMT_ULONG)
		elseif (eltype(ptr) == Int64)		Mb._type = UInt32(GMT.GMT_LONG)
		elseif (eltype(ptr) == UInt32)		Mb._type = UInt32(GMT.GMT_UINT)
		elseif (eltype(ptr) == Int32)		Mb._type = UInt32(GMT.GMT_INT)
		elseif (eltype(ptr) == UInt16)		Mb._type = UInt32(GMT.GMT_USHORT)
		elseif (eltype(ptr) == Int16)		Mb._type = UInt32(GMT.GMT_SHORT)
		elseif (eltype(ptr) == UInt8)		Mb._type = UInt32(GMT.GMT_UCHAR)
		elseif (eltype(ptr) == Int8)		Mb._type = UInt32(GMT.GMT_CHAR)
		else
			println("Type ", typeof(ptr), " not allowed")
			error("GMTJL_matrix_init: only integer or floating point types allowed in input. Others need to be added")
		end
		Mb.data = pointer(ptr)
		Mb.dim  = Mb.n_rows		# Data from Julia is in column major
		Mb.alloc_mode = GMT.GMT_ALLOC_EXTERNALLY;	# Since matrix was allocated by Julia
		Mb.shape = GMT.GMT_IS_COL_FORMAT;			# Julia order is column major
		unsafe_store!(M, Mb)
		return M

	else	# To receive data from GMT we use a GMT_VECTOR resource instead
		# There are no dimensions and we are just getting an empty container for output
		if ((V = GMT_Create_Data(API, GMT_IS_VECTOR, GMT_IS_PLP, 0, C_NULL, C_NULL, C_NULL, 0, 0, C_NULL)) == C_NULL)
			error("GMTJL_dataset_init: Failure to alloc GMT source vector\n")
		end
		GMT_Report(API, GMT_MSG_DEBUG, @sprintf("GMTJL_dataset_init: Allocated GMT Vector %s\n", V))
		return V
	end
end

# ---------------------------------------------------------------------------------------------------
function GMTJL_CPT_init(API::Ptr{Void}, module_input, cpt, dir::Integer)
	# Used to Create an empty CPT container to hold a GMT CPT.
 	# If direction is GMT_IN then we are given a Matlab CPT and can determine its size, etc.
	# If direction is GMT_OUT then we allocate an empty GMT CPT as a destination.

	if (dir == GMT_IN)	# Dimensions are known from the input pointer

		if (!isa(cpt, GMTJL_CPT))
			error("GMTJL_CPT_init: Expected a CPT structure for input")
		end

		#error("GMTJL_CPT_init: Could not find colormap array with CPT values")
		#error("GMTJL_CPT_init: Could not find range array for CPT range")
		#error("GMTJL_CPT_init: Could not find alpha array for CPT transparency")

		n_colors = size(cpt.colormap, 1)	# n_colors != n_ranges for continuous CPTs 
		n_ranges = size(cpt.range, 1)
		one = 1
		if (n_colors > n_ranges)		# Continuous
			n_ranges = n_colors;		# Actual length of colormap array
			n_colors = n_colors - 1;	# Number of CPT slices
		else
			one = 0
		end

		if ((P = GMT_Create_Data(API, GMT_IS_CPT, GMT_IS_NONE, 0, pointer([n_colors]), C_NULL, C_NULL, 0, 0, C_NULL)) == C_NULL)
			error("GMTJL_CPT_init: Failure to alloc GMT source CPT for input")
		end

		if (one != 0)
			mutateit(API, P, "is_continuous", one)
		end

		Pb = unsafe_load(P)

		#dz = (cpt.range[2] - cpt.range[1]) / Pb.n_colors
		for (j = 1:Pb.n_colors)
			glut = unsafe_load(Pb.range, j)
			rgb_low  = (cpt.colormap[j,1], cpt.colormap[j,2], cpt.colormap[j,3], cpt.alpha[j])
			rgb_high = (cpt.colormap[j+one,1], cpt.colormap[j+one,2], cpt.colormap[j+one,3], cpt.alpha[j+one])
			z_low  = cpt.range[j,1]
			z_high = cpt.range[j,2]
			#z_low = j * dz
			#z_high = (j+1) * dz

			#mutateit(API, glut, "annot", 3)		# Enforce annotations for now. But it FAILS too
			#annot = glut.annot
			annot = 3						# Enforce annotations for now
			lut = GMT_LUT(z_low, z_high, glut.i_dz, rgb_low, rgb_high, glut.rgb_diff, glut.hsv_low, glut.hsv_high,
			              glut.hsv_diff, annot, glut.skip, glut.fill, glut.label)

			unsafe_store!(Pb.range, lut, j)
		end
		unsafe_store!(P, Pb)
	else 	# Just allocate an empty container to hold an output grid (signal this by passing NULLs)
		if ((P = GMT_Create_Data(API, GMT_IS_CPT, GMT_IS_NONE, 0, C_NULL, C_NULL, C_NULL, 0, 0, C_NULL)) == C_NULL)
			error("GMTJL_CPT_init: Failure to alloc GMT blank CPT container for holding output CPT")
		end
	end

	return P
end


# ---------------------------------------------------------------------------------------------------
function GMTJL_Text_init(API::Ptr{Void}, module_input, txt, dir::Integer, family::Integer=GMT_IS_TEXTSET)
	# Used to Create an empty Textset container to hold a GMT TEXTSET.
 	# If direction is GMT_IN then we are given a Julia cell array and can determine its size, etc.
	# If direction is GMT_OUT then we allocate an empty GMT TEXTSET as a destination.


	# Disclaimer: This code is absolutely diabolic. Thanks to immutables.

	if (dir == GMT_IN)	# Dimensions are known from the input pointer

		#if (module_input) family |= GMT_VIA_MODULE_INPUT;	gmtmex_parser.c has this which is not ported yet
	
		if (!isa(txt, Array{Any}) && isa(txt, ASCIIString))
			txt = Any[txt]
		elseif (isa(txt, Matrix))
			txt = num2str(txt)			# Convert the numeric matrix into a cell array of strings
		end
		if (!isa(txt, Array{Any}))
			error("GMTJL_Text_init: Expected a Cell array or a String for input")
		end

		dim = [1 1 0]
		dim[3] = size(txt, 1)
		if (dim[3] == 1)                # Check if we got a transpose arrangement or just one record
			rec = size(txt, 2)          # Also possibly number of records
			if (rec > 1) dim[3] = rec end  # User gave row-vector of cells
		end

		if ((T = GMT_Create_Data(API, family, GMT_IS_NONE, 0, pointer(dim), C_NULL, C_NULL, 0, 0, C_NULL)) == C_NULL)
			error("GMTJL_Text_init: Failure to alloc GMT source TEXTSET for input")
		end
		mutateit(API, T, "alloc_mode", GMT_ALLOC_EXTERNALLY)
		#GMT_blind_change_struct_(API, T, pointer([GMT_ALLOC_EXTERNALLY]), "API_ALLOCMODE_T")

		T0 = pointer_to_array(T, 1)		# ::Array{GMT.GMT_TEXTSET,1}

		TTABLE  = unsafe_load(unsafe_load(T0[1].table,1),1)		# ::GMT.GMT_TEXTTABLE
		S0 = unsafe_load(unsafe_load(TTABLE.segment,1),1)		# ::GMT.GMT_TEXTSEGMENT

		for (rec = 1:dim[3])
			unsafe_store!(S0.record, pointer(txt[rec]), rec)
		end
		
		#GMT_blind_change_struct_(API, unsafe_load(TTABLE.segment,1), pointer([dim[3]]), "API_STRUCT_MEMBER_TEXTSEGMENT_1")
		mutateit(API, unsafe_load(TTABLE.segment,1), "n_rows", dim[3])

		# This chunk is no longer need as long as it works the call to GMT_Set_alloc_mode() that sets
		# the number of rows using very uggly tricks via C. The problem with the commented code below
		# comes from the GMT GarbageMan that would crash Julia when attempting to free a the Julia owned TS

#=
		TS = GMT_TEXTSEGMENT(dim[3], S0.record, S0.label, S0.header, S0.id, S0.mode, S0.n_alloc,
		                     S0.file, S0.tvalue)

		#segment::Ptr{Ptr{GMT_TEXTSEGMENT}}
		TSp1 = pointer([TS])		# ::Ptr{GMT_TEXTSEGMENT}
		TSp2 = pointer([TSp1])		# ::Ptr{Ptr{GMT_TEXTSEGMENT}}
		TT0  = TTABLE               # ::GMT_TEXTTABLE
		TT = GMT_TEXTTABLE(TT0.n_headers, TT0.n_segments, dim[3], TT0.header, TSp2, TT0.id, TT0.n_alloc,
		                   TT0.mode, TT0.file)
		pointer_to_array(TSp2,1)	# Just to prevent the garbage man to destroy TSp? before this time
		TTp1 = pointer([TT])		# ::Ptr{GMT_TEXTTABLE}
		TTp2 = pointer([TTp1])		# ::Ptr{Ptr{GMT_TEXTTABLE}}
		# Actually, here it ignores all but the pointers (TTp2)
		Tt   = GMT_TEXTSET(T0[1].n_tables, T0[1].n_segments, dim[3], TTp2, T0[1].id, T0[1].n_alloc, T0[1].geometry,
		                   T0[1].alloc_level, T0[1].io_mode, GMT.GMT_ALLOC_EXTERNALLY, T0[1].file)
		pointer_to_array(TTp2,2)	# Just to prevent the GarbageMan to destroy TTp? before this time
		unsafe_store!(T, Tt)
=#

	else 	# Just allocate an empty container to hold an output grid (signal this by passing NULLs)
		if ((T = GMT_Create_Data(API, GMT_IS_TEXTSET, GMT_IS_NONE, 0, C_NULL, C_NULL, C_NULL, 0, 0, C_NULL)) == C_NULL)
			error("GMTJL_Text_init: Failure to alloc GMT blank TEXTSET container for holding output TEXT")
		end
	end

	return T
end

# ---------------------------------------------------------------------------------------------------
function GMTJL_PS_init(API::Ptr{Void}, module_input, ptr, direction::Integer)
# ...
	if ((PS = GMT_Create_Data(API, GMT_IS_PS, GMT_IS_NONE, 0, C_NULL, C_NULL, C_NULL, 0, 0, C_NULL)) == C_NULL)
		error("GMTJL_PS_init: Failure to alloc GMT blank PS container for holding output PostScript")
	end
	return PS
end

# ---------------------------------------------------------------------------------------------------
function convert_string(str)
# Convert a string stored in one of those GMT.Array_XXX_Uint8 types into an ascii string
	k = 1
	while (str.(k) != UInt8(0))
		k = k + 1
	end
	out = join([Char(str.(n)) for n=1:k])
end

# ---------------------------------------------------------------------------------------------------
function GMTJL_type(API::Ptr{Void})		# Set default export type
	value = "        "		# 8 spaces
	GMT_Get_Default(API, "GMT_EXPORT_TYPE", value)
	if (strncmp(value, "double", 6)) return DOUBLE_CLASS	end
	if (strncmp(value, "single", 6)) return SINGLE_CLASS	end
	if (strncmp(value, "long",   4)) return  INT64_CLASS	end
	if (strncmp(value, "ulong",  5)) return UINT64_CLASS	end
	if (strncmp(value, "int",    3)) return  INT32_CLASS	end
	if (strncmp(value, "uint",   4)) return UINT32_CLASS	end
	if (strncmp(value, "short",  5)) return  INT16_CLASS	end
	if (strncmp(value, "ushort", 6)) return UINT16_CLASS	end
	if (strncmp(value, "char",   4)) return   INT8_CLASS	end
	if (strncmp(value, "uchar",  5)) return  UINT8_CLASS	end
	
	println("Unable to interpret GMT_EXPORT_TYPE - Default to double")
	return DOUBLE_CLASS
end

# ---------------------------------------------------------------------------------------------------
function get_datatype(var)
# Get the data type of VAR
	if (eltype(var) == Float64) return DOUBLE_CLASS	end
	if (eltype(var) == Float32) return SINGLE_CLASS	end
	if (eltype(var) == UInt64) 	return UINT64_CLASS	end
	if (eltype(var) == Int64) 	return INT64_CLASS	end
	if (eltype(var) == UInt32) 	return UINT32_CLASS	end
	if (eltype(var) == Int32) 	return INT32_CLASS	end
	if (eltype(var) == UInt16) 	return UINT16_CLASS	end
	if (eltype(var) == Int16) 	return INT16_CLASS	end
	if (eltype(var) == UInt8) 	return UINT8_CLASS	end
	if (eltype(var) == Int8) 	return INT8_CLASS	end
	
	println("Unable to discovery this data type - Default to double")
	return DOUBLE_CLASS
end

# ---------------------------------------------------------------------------------------------------
function strncmp(str1, str2, num)
# Pseudo strncmp
	a = str1[1:min(num,length(str1))] == str2
end

# ---------------------------------------------------------------------------------------------------
function mutateit(API::Ptr{Void}, t_type, member::ASCIIString, val)
	# Mutate the member 'member' of an immutable type whose pointer is T_TYPE
	# VAL is the new value of the MEMBER field.
	# It's up to the user to guarantie that MEMBER and VAL have the same data type
	# T_TYPE can actually be either a variable of a certain type or a pointer to it.
	# In latter case, we fish the specific DataType from it.
	if (isa(t_type, Ptr))
		x_type = unsafe_load(t_type)
		p_type = t_type
	else
		x_type = t_type
		p_type = pointer([t_type])	# We need the pointer to type to later send to GMT_blind_change
	end
	dt = typeof(x_type)			# Get the specific DataType. That's what we'll need for next inquires
	fo = fieldoffsets(dt);		ft = dt.types
	ind = findfirst(fieldnames(dt), symbol(member))	# Find the index of the "is_continuous" member
	# This would work too
	# ind = ccall(:jl_field_index, Cint, (Any, Any, Cint), dt, symbol(member), 1) + 1
	if (isa(val, AbstractString))	# No idea why I have to do this
		p_val = pointer(val)
	else
		p_val = pointer([val])
	end
	GMT_blind_change_struct(API, p_type, p_val, @sprintf("%s",ft[ind]), fo[ind])
	typeof(p_type); 	typeof(p_val)		# Just to be sure that GC doesn't kill them before their due time
end

# ---------------------------------------------------------------------------------------------------
function num2str(mat)
# Pseudo num2str, but returns all in a cell array of strings and no precision control yet.
	n_cols = size(mat, 2);		n_rows = size(mat, 1)
	out = cell(n_rows, 1)
	for (nr = 1:n_rows)
		out[nr] = join([@sprintf("%s ", mat[k]) for k=1:n_cols])
	end
	return out
end

# ---------------------------------------------------------------------------------------------------
"""
G = grid_type(z, hdr=[])
    Take a 2D Z array and a HDR 1x9 [xmin xmax ymin ymax zmin zmax ref xinc yinc] header descriptor
    and return a grid GMTJL_GRID type.
    Optionaly, the HDR arg may be ommited and it will computed from Z alone, but than x=1:ncol, y=1:nrow
"""
function grid_type(z, hdr=[])
	n_rows = size(z,1);		n_cols = size(z,2)
	if (n_rows == 1 || n_cols == 1)
		error("Z must be a 2D array")
	end
	if (isempty(hdr))
		zmin, zmax = extrema(z)
		hdr = [1. n_cols 1. n_rows zmin zmax 0 1 1]
	elseif (length(hdr) != 9)
		error("The HDR array must have 9 elements")
	end
	x = linspace(hdr[1], hdr[2], n_cols)
	y = linspace(hdr[3], hdr[4], n_rows)
	# Recompute the x|y_inc to make sure they are right.
	one_or_zero = hdr[7] == 0 ? 1 : 0
	x_inc = (hdr[2] - hdr[1]) / (n_cols - one_or_zero)
	y_inc = (hdr[4] - hdr[3]) / (n_rows - one_or_zero)
	G = GMTJL_GRID("", "", hdr[1:6], [x_inc, y_inc], n_rows, n_cols, 1, hdr[7], NaN, "", "", "", "", x, y, z, "", "", "")
end


#=
Em GMT_Create_Session(API, ...)
	API->pad = pad;

O GMT_begin chama indirectamente esta
void GMT_set_pad (struct GMT_CTRL *GMT, unsigned int pad) {
	GMT->current.io.pad[XLO] = GMT->current.io.pad[XHI] = GMT->current.io.pad[YLO] = GMT->current.io.pad[YHI] = pad;
}
=#