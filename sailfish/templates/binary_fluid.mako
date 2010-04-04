<%!
    from sailfish import sym
    import sympy
%>

<%def name="bgk_args_decl_sc()">
	float rho, float phi, float *iv0, float *ea0, float *ea1
</%def>

<%def name="bgk_args_decl_fe()">
	float rho, float phi, float lap1, float *iv0, float *grad1
</%def>

<%def name="bgk_args_sc()">
	g0m0, g1m0, v, sca0, sca1
</%def>

<%def name="bgk_args_fe()">
	g0m0, g1m0, lap1, v, grad1
</%def>

// In the free-energy model, the relaxation time is a local quantity.
%if simtype == 'shan-chen':
	${const_var} float tau0 = ${tau}f;		// relaxation time
%endif
${const_var} float tau1 = ${tau_phi}f;		// relaxation time for the order parameter
${const_var} float visc = ${visc}f;		// viscosity

<%namespace file="opencl_compat.mako" import="*" name="opencl_compat"/>
<%namespace file="kernel_common.mako" import="*" name="kernel_common"/>
%if simtype == 'shan-chen':
	${kernel_common.body(bgk_args_decl_sc)}
%elif simtype == 'free-energy':
	${kernel_common.body(bgk_args_decl_fe)}
%endif
<%namespace file="code_common.mako" import="*"/>
<%namespace file="boundary.mako" import="*" name="boundary"/>
<%namespace file="relaxation.mako" import="*" name="relaxation"/>
<%namespace file="propagation.mako" import="*"/>

<%include file="finite_difference_optimized.mako"/>

// A kernel to set the node distributions using the equilibrium distributions
// and the macroscopic fields.
${kernel} void SetInitialConditions(
	${global_ptr} float *dist1_in,
	${global_ptr} float *dist2_in,
	${kernel_args_1st_moment('iv')}
	${global_ptr} float *irho,
	${global_ptr} float *iphi)
{
	${local_indices()}

	%if simtype == 'free-energy':
		float lap1, grad1[${dim}];
		%if dim == 2:
			laplacian_and_grad(iphi, gi, &lap1, grad1, gx, gy);
		%else:
			laplacian_and_grad(iphi, gi, &lap1, grad1, gx, gy, gz);
		%endif
	%endif

	// Cache macroscopic fields in local variables.
	float rho = irho[gi];
	float phi = iphi[gi];
	float v0[${dim}];

	v0[0] = ivx[gi];
	v0[1] = ivy[gi];
	%if dim == 3:
		v0[2] = ivz[gi];
	%endif

	%for local_var in bgk_equilibrium_vars:
		float ${cex(local_var.lhs)} = ${cex(local_var.rhs, vectors=True)};
	%endfor

	%for i, (feq, idx) in enumerate(bgk_equilibrium[0]):
		${get_odist('dist1_in', i)} = ${cex(feq, vectors=True)};
	%endfor

	%for i, (feq, idx) in enumerate(bgk_equilibrium[1]):
		${get_odist('dist2_in', i)} = ${cex(feq, vectors=True)};
	%endfor
}

${kernel} void PrepareMacroFields(
	${global_ptr} int *map,
	${global_ptr} float *dist1_in,
	${global_ptr} float *dist2_in,
	${global_ptr} float *orho,
	${global_ptr} float *ophi)
{
	${local_indices()}

	int type, orientation;
	decodeNodeType(map[gi], &orientation, &type);

	// Unused nodes do not participate in the simulation.
	if (isUnusedNode(type))
		return;

	int igi = gi;

	%if simtype == 'free-energy':
		// Assume neutral wetting for all walls.
		if (isWallNode(type)) {
			if (0) { ; }
			%for dir in grid.dir2vecidx.keys():
				else if (orientation == ${dir}) {
					%if dim == 3:
						igi += ${rel_offset(*(2*grid.dir_to_vec(dir)))};
					%else:
						igi += ${rel_offset(*(list(2*grid.dir_to_vec(dir)) + [0]))};
					%endif
				}
			%endfor
		}
	%endif

	// cache the distributions in local variables
	Dist fi;
	float out;

	getDist(&fi, dist1_in, igi);
	get0thMoment(&fi, type, orientation, &out);
	orho[gi] = out;

	getDist(&fi, dist2_in, igi);
	get0thMoment(&fi, type, orientation, &out);
	ophi[gi] = out;
}

${kernel} void CollideAndPropagate(
	${global_ptr} int *map,
	${global_ptr} float *dist1_in,
	${global_ptr} float *dist1_out,
	${global_ptr} float *dist2_in,
	${global_ptr} float *dist2_out,
	${global_ptr} float *gg0m0,
	${global_ptr} float *gg1m0,
	${kernel_args_1st_moment('ov')}
	int save_macro)
{
	${local_indices()}

	// shared variables for in-block propagation
	%for i in sym.get_prop_dists(grid, 1):
		${shared_var} float prop_${grid.idx_name[i]}[BLOCK_SIZE];
	%endfor
	%for i in sym.get_prop_dists(grid, -1):
		${shared_var} float prop_${grid.idx_name[i]}[BLOCK_SIZE];
	%endfor

	int type, orientation;
	decodeNodeType(map[gi], &orientation, &type);

	// Unused nodes do not participate in the simulation.
	if (isUnusedNode(type))
		return;

	%if simtype == 'free-energy':
		float lap1, grad1[${dim}];

		if (!isWallNode(type)) {
			%if dim == 2:
				laplacian_and_grad(gg1m0, gi, &lap1, grad1, gx, gy);
			%else:
				laplacian_and_grad(gg1m0, gi, &lap1, grad1, gx, gy, gz);
			%endif
		}
	%elif simtype == 'shan-chen':
		${sc_calculate_accel()}
	%endif

	// cache the distributions in local variables
	Dist d0, d1;
	getDist(&d0, dist1_in, gi);
	getDist(&d1, dist2_in, gi);

	// macroscopic quantities for the current cell
	float g0m0, v[${dim}], g1m0;

	%if simtype == 'free-energy':
		getMacro(&d0, type, orientation, &g0m0, v);
		get0thMoment(&d1, type, orientation, &g1m0);
	%elif simtype == 'shan-chen':
		${sc_macro_fields()}
	%endif

	boundaryConditions(&d0, type, orientation, &g0m0, v);
	boundaryConditions(&d1, type, orientation, &g1m0, v);
	${barrier()}

	%if simtype == 'shan-chen':
		${relaxate(bgk_args_sc)}
	%elif simtype == 'free-energy':
		${relaxate(bgk_args_fe)}
	%endif

	// only save the macroscopic quantities if requested to do so
	if (save_macro == 1) {
		ovx[gi] = v[0];
		ovy[gi] = v[1];
		%if dim == 3:
			ovz[gi] = v[2];
		%endif
	}

	${propagate('dist1_out', 'd0')}
	${barrier()}
	${propagate('dist2_out', 'd1')}
}

