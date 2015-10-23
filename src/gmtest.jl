# Run a  test from the GALLERY, tests or doc/scripts
#
# gmtest(test) run an example from the gallery were TEST is is either 'ex01' ... 'ex45'
#
# gmtest(test, test_dir) runs a test from the tests suit. TEST_DIR is the directory name where TEST live
#		example: gmtest("poldecimate","gmtspatial")
#
# gmtest(test, test_dir, family) runs a test from a certainly family of tests.
#	Currently only family = "scripts" is implemented (means run test from the 'scripts' dir. TEST_DIR is ignored
#		example: gmtest("GMT_insert", "", "scripts")

global g_root_dir, out_path
include("C:/progs_cygw/GMTdev/GMT.jl/src/gallery.jl")

# Edit those two for your own needs
g_root_dir = "C:/progs_cygw/GMTdev/gmt5/branches/5.2.0/"
out_path = "V:/"		# Set this if you want to save the PS files in a prticular place


function run_tests(what::ASCIIString)
	if (what == "all_examples")
		for (k = 1:45)
			ex = @sprintf("ex%02d", k)
			gmtest(ex)
		end
	elseif (what == "all_tests")
		do_tests()
	end
end

# ----------------------------------------------------------------------------------------
gmtest(test, test_dir::ASCIIString, family::ASCIIString) = gmtest(test, test_dir, family, 3)
function gmtest(test, test_dir="", family="", nargin::Int=1)
# Run an example or test and print its tested status, i.e. if it PASS or FAIL

	global g_root_dir, out_path

	GRAPHICSMAGICK = "C:/programs/GraphicsMagick/gm.exe"

	if ((nargin == 1) && (length(test) == 4) && startswith(test, "ex"))	# Run example from gallery
		ps, orig_path = gallery(test)
	else
		ps, orig_path = call_test(test, test_dir, g_root_dir, out_path, family)
		if (isa(ps, Bool))
			if (ps)		println("Test " * test * " PASS")
			else 		println("Test " * test * " FAIL")
			end
			return
		end
	end

	if (isempty(ps))
		println("    Test -> " * test * " <- does not exist or some other error occurred")
		return
	end
	pato, fname = fileparts(ps)
	png_name = pato * fname * ".png"
	ps_orig  = orig_path * fname * ".ps"

	# Compare the ps file with its original.
	cm = `$GRAPHICSMAGICK compare -density 200 -maximum-error 0.001 -highlight-color magenta -highlight-style
		 assign -metric rmse -file $png_name $ps_orig $ps`

	run(pipeline(ignorestatus(cm), stdout=DevNull, stderr="errs.txt"))
	t = readall("errs.txt");
	rm("errs.txt")
	if (isempty(t))
		println("    Test " * test * " PASS")
		rm(png_name)
	else
		ind = searchindex(t, "image")
		println("    Test " * test * " FAIL with: " * t[ind:end-1])
	end
end

# ---------------------------------------------------------------------------------------
function call_test(test, test_dir, g_root_dir, out_path, family)
# Here PS hold the full name of the created PS file and ORIG_PATH must
# contain the path to where the original postscript file, against which the PS will be compared

	ps = [];	orig_path = [];					# Defaults for the case of error
	if (isempty(family))						# A test from the tests suit
		pato = g_root_dir * "test/" * test_dir * "/"
	elseif (family == "scripts")				# A test for the 'scripts' directory
		pato = g_root_dir * "doc/scripts/ml/"
	else
		@sprintf("Family %s is unknown or not yet implemented", family)
		return
	end

	#try
		#ps, orig_path = evalfile(pato * test * ".jl")(out_path)	# Load & run the test file. Errors because UndefVarError: fileparts not defined
		include(pato * test * ".jl")					# Load the test file
		ps, orig_path = eval(Symbol(test))(out_path)	# and now run it
		if (family == "scripts")
			orig_path = orig_path[1:end-3]				# Because original PS lieve in a subdir below
		end
	#catch
		#println("Error executing test script")
	#end
	return ps, orig_path
end

# ---------------------------------------------------------------------------------------
function do_tests()
	tests = Any["poldecimate" "gmtspatial";
	            "spheres" "potential"]

	for (k = 1:size(tests,1))
		gmtest(tests[k,1], tests[k,2])
	end
end

# ---------------------------------------------------------------------------------------
function fileparts(file)
	path = dirname(file)
	f = basename(file)
	fname, ext = splitext(f)
	return path, fname, ext
end

# ---------------------------------------------------------------------------------------
function addpath(path)
	push!(LOAD_PATH, path)
end

# ---------------------------------------------------------------------------------------
function mfilename(arg)
# If ARG == "fullpath" return the full path of the script being rin, otherwise only its name.
# But the problem with this function is that it WONT WORK because it always return the path to gmtest.jl
	t = @__FILE__
	path, fname = fileparts(t)
	if (arg == "fullpath")
		return path * fname
	else
		return fname
	end
end

mfilename() = mfilename("treta")	# Output only the script name

# ---------------------------------------------------------------------------------------
feval(fn_str, args...) = eval(parse(fn_str))(args...)
