! ***********************************************************************
!
!   Copyright (C) 2010-2019  Bill Paxton & The MESA Team
!
!   MESA is free software; you can use it and/or modify
!   it under the combined terms and restrictions of the MESA MANIFESTO
!   and the GNU General Library Public License as published
!   by the Free Software Foundation; either version 2 of the License,
!   or (at your option) any later version.
!
!   You should have received a copy of the MESA MANIFESTO along with
!   this software; if not, it is available at the mesa website:
!   http://mesa.sourceforge.net/
!
!   MESA is distributed in the hope that it will be useful,
!   but WITHOUT ANY WARRANTY; without even the implied warranty of
!   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
!   See the GNU Library General Public License for more details.
!
!   You should have received a copy of the GNU Library General Public License
!   along with this software; if not, write to the Free Software
!   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
!
! ***********************************************************************

      module evolve

      use star_private_def
      use const_def
      use star_utils
 
      implicit none

      private
      public :: do_evolve_step_part1, do_evolve_step_part2, &
         pick_next_timestep, prepare_to_redo, prepare_to_retry, &
         finish_step, set_age


      contains


      integer function do_evolve_step_part1(id, first_try)
         logical, intent(in) :: first_try
         integer, intent(in) :: id
         type (star_info), pointer :: s
         integer :: ierr
         do_evolve_step_part1 = terminate
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         do_evolve_step_part1 = do_step_part1(id, first_try)
         s% total_step_attempts = s% total_step_attempts + 1
         if (s% doing_relax) &
            s% total_relax_step_attempts = s% total_relax_step_attempts + 1
         if (do_evolve_step_part1 == redo) then
            s% total_step_redos = s% total_step_redos + 1
            if (s% doing_relax) &
               s% total_relax_step_redos = s% total_relax_step_redos + 1
         else if (do_evolve_step_part1 == retry) then
            s% total_step_retries = s% total_step_retries + 1
            if (s% doing_relax) &
               s% total_relax_step_retries = s% total_relax_step_retries + 1
         end if
      end function do_evolve_step_part1
      

      integer function do_step_part1(id, first_try)
         use hydro_vars, only: set_vars
         use winds, only: set_mdot
         use alloc, only: check_sizes, fill_star_info_arrays_with_NaNs
         use do_one_utils, only: write_terminal_header
         use hydro_vars, only: set_vars_if_needed, set_vars
         use solve_hydro, only: set_L_burn_by_category
         use mix_info, only: set_cz_bdy_mass
         use star_utils, only: eval_total_energy_integrals, save_for_d_dt, &
            cell_specific_total_energy, reset_epsnuc_vectors
         use report, only: do_report
         use rsp, only: rsp_total_energy_integrals
         logical, intent(in) :: first_try
         integer, intent(in) :: id

         type (star_info), pointer :: s
         integer :: ierr, j, k
         integer(8) :: time0, clock_rate
         logical :: trace
         real(dp) :: total_radiation

         logical, parameter :: dbg = .false.

         include 'formats'

         do_step_part1 = terminate
         ierr = 0
         call get_star_ptr(id, s, ierr)
         if (ierr /= 0) return
         
         if (s% timestep_hold > s% model_number + 10000) then 
            write(*,3) 'ERROR: s% timestep_hold', s% timestep_hold, s% model_number
            stop 'do_step_part1'
         end if
         
         if (s% steps_before_start_stress_test >= 0 .and. &
             s% model_number >= s% steps_before_start_stress_test .and. &
             (s% stress_test_relax .or. .not. s% doing_relax)) then
            !s% use_gold2_tolerances = .true.
            !s% gold2_iter_for_resid_tol3 = 999
            !s% gold2_tol_residual_norm2 = 1d-8
            !s% gold2_tol_max_residual2 = 1d-5 
               ! 1d-6 breaks cburn_inward because of poor HELM partials at logT 8.8, logRho 5.8
         end if

         if (s% u_flag .and. s% v_flag) then
            write(*,*) 'must not have both u_flag and v_flag at the same time'
            return
         end if

         call system_clock(s% system_clock_at_start_of_step, clock_rate)
         
         s% termination_code = 0
         s% retry_message = ''
         trace = s% trace_evolve
         s% doing_solver_iterations = .false.
         s% num_rotation_solver_steps = 0
         s% have_mixing_info = .false.
         s% L_for_BB_outer_BC = -1 ! mark as not set
         
         s% need_to_setvars = .true. ! always start fresh
         s% okay_to_set_mixing_info = .true. ! set false by element diffusion

         if (s% doing_first_model_of_run) then
            if (s% do_history_file) then
               if (first_try) then
                  call write_terminal_header(s)
               else
                  write(*,1) '1st model retry log10(dt/yr)', log10(s% dt/secyer)
               end if
            end if
            call system_clock(time0,clock_rate)
            s% starting_system_clock_time = time0
            s% system_clock_rate = clock_rate
            s% initial_timestep = s% dt_next
            s% initial_L_center = s% L_center
            s% initial_R_center = s% R_center
            s% initial_v_center = s% v_center
            s% timestep_hold = -111
            if (first_try) s% model_number_old = s% model_number
         end if

         if (first_try) then ! i.e., not a redo or retry
            s% have_new_generation = .false.
            do_step_part1 = prepare_for_new_step(s)
            if (do_step_part1 /= keep_going) then
               if (s% report_ierr) &
                  write(*,*) 'do_step_part1: prepare_for_new_step'
               return
            end if
            s% have_new_generation = .true.
            s% have_new_cz_bdy_info = .false.
            if (s% steps_before_use_Fraley_time_centering >= 0 .and. &
                s% model_number > s% steps_before_use_Fraley_time_centering) &
               s% using_Fraley_time_centering = .true.
         end if
         
         call reset_epsnuc_vectors(s)
         
         do_step_part1 = prepare_for_new_try(s)
         if (do_step_part1 /= keep_going) then
            if (s% report_ierr) &
               write(*,*) 'do_step_part1: prepare_for_new_try'
            return
         end if
         
         call set_start_of_step_info(s, 'after prepare_for_new_try', ierr) ! does set_vars_if_needed
         if (failed('set_start_of_step_info')) return

         if (.not. s% have_new_cz_bdy_info) then
            call set_cz_bdy_mass(s, ierr)
            if (failed('set_cz_bdy_mass')) return
         end if
         
         if (s% RSP_flag) then
            s% mstar_dot = 0
            call rsp_total_energy_integrals(s, &
               s% total_internal_energy_old, &
               s% total_gravitational_energy_old, &
               s% total_radial_kinetic_energy_old, &
               s% total_rotational_kinetic_energy_old, &
               s% total_turbulent_energy_old, &
               s% total_energy_old, total_radiation)
         else
            call set_mdot(s, s% L_phot*Lsun, s% mstar, s% Teff, ierr)
            if (ierr /= 0) then
               do_step_part1 = retry
               s% result_reason = nonzero_ierr
               if (s% report_ierr) write(*, *) 'do_step_part1 set_mdot'
               return
            end if
            ! set energy info for new mesh
            call eval_total_energy_integrals(s, &
               s% total_internal_energy_old, &
               s% total_gravitational_energy_old, &
               s% total_radial_kinetic_energy_old, &
               s% total_rotational_kinetic_energy_old, &
               s% total_turbulent_energy_old, &
               s% total_energy_old)
         end if
                  
         s% surface_cell_specific_total_energy_old = cell_specific_total_energy(s,1)

         if (.not. s% have_initial_energy_integrals) then
            s% total_internal_energy_initial = &
               s% total_internal_energy_old
            s% total_gravitational_energy_initial = &
               s% total_gravitational_energy_old
            s% total_radial_kinetic_energy_initial = &
               s% total_radial_kinetic_energy_old
            s% total_rotational_kinetic_energy_initial = &
               s% total_rotational_kinetic_energy_old
            s% total_turbulent_energy_initial = s% total_turbulent_energy_old
            s% total_energy_initial = s% total_energy_old
            s% have_initial_energy_integrals = .true.
         end if

         contains

         logical function failed(str)
            character (len=*), intent(in) :: str
            if (ierr == 0) then
               failed = .false.
               return
            end if
            failed = .true.
            do_step_part1 = retry
            if (s% report_ierr) write(*, *) 'do_step_part1 ' // trim(str)
            s% result_reason = nonzero_ierr
         end function failed

      end function do_step_part1


      integer function do_evolve_step_part2(id, first_try)
         logical, intent(in) :: first_try
         integer, intent(in) :: id
         type (star_info), pointer :: s
         integer :: ierr
         do_evolve_step_part2 = terminate
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         do_evolve_step_part2 = do_step_part2(id, first_try)
         if (do_evolve_step_part2 == redo) then
            s% total_step_redos = s% total_step_redos + 1
            if (s% doing_relax) &
               s% total_relax_step_redos = s% total_relax_step_redos + 1
         else if (do_evolve_step_part2 == retry) then
            s% total_step_retries = s% total_step_retries + 1
            if (s% doing_relax) &
               s% total_relax_step_retries = s% total_relax_step_retries + 1
         else ! keep_going or terminate both count as finished
            s% total_steps_finished = s% total_steps_finished + 1
            if (s% doing_relax) &
               s% total_relax_steps_finished = s% total_relax_steps_finished + 1
         end if
      end function do_evolve_step_part2


      integer function do_step_part2(id, first_try)
         use num_def
         use chem_def
         use report, only: do_report
         use adjust_mass, only: do_adjust_mass
         use element_diffusion, only: do_element_diffusion, finish_element_diffusion
         use conv_premix, only: do_conv_premix
         use evolve_support, only: set_current_to_old
         use eps_mdot, only: calculate_eps_mdot
         use struct_burn_mix, only: do_struct_burn_mix
         use hydro_vars, only: set_vars_if_needed, set_vars, set_final_vars, set_cgrav
         use hydro_mtx, only: dump_struct
         use star_utils, only: start_time, update_time, get_phot_info
         use solve_omega_mix, only: do_solve_omega_mix
         use mix_info, only: set_cz_bdy_mass, set_mixing_info
         use hydro_rotation, only: set_rotation_info, set_i_rot
         use solve_hydro, only: set_L_burn_by_category
         use winds, only: set_mdot
         use star_utils, only: &
            eval_integrated_total_energy_profile, eval_deltaM_total_energy_integrals
         use profile

         logical, intent(in) :: first_try
         integer, intent(in) :: id

         type (star_info), pointer :: s
         integer :: ierr, time0, clock_rate, &
            j, k, j_cnt, mdot_redo_cnt, max_mdot_redo_cnt, cnt, max_cnt, nz
         logical :: okay, trace, skip_global_corr_coeff_limit, &
            have_too_large_wind_mdot, have_too_small_wind_mdot, &
            ignored_first_step, was_in_implicit_wind_limit
         real(dp) :: J_tot1, J_tot2, rel_error, &
            w_div_w_crit, w_div_w_crit_prev, mstar_dot, mstar_dot_prev, abs_mstar_delta, &
            explicit_mdot, max_wind_mdot, wind_mdot, r_phot, kh_timescale, dmskhf, dmsfac, &
            too_large_wind_mdot, too_small_wind_mdot, boost, mstar_dot_nxt, total, &
            surf_w_div_w_crit_limit, dt, time, max_dt, total_energy, &
            new_R_center, amplitude, flash_max, &
            dm_nz, dm_m1, r_m1, v_m1, A_nz, A_m1, A_center, new_v_center, min_v_center
            
         integer :: ph_k, mdot_action
         real(dp) :: r, m, xm, v, L, cs, kap, ysum, &
            implicit_mdot, ph_x, ph_L, iwind_tolerance, iwind_lambda, total_nuclear_heating, &
            total_radiation
         integer :: k_phot, iwind_redo_cnt, iwind_max_redo_cnt
         integer, parameter :: exit_loop = 1, cycle_loop = 0

         logical, parameter :: dbg = .false.

         include 'formats'
         
         ierr = 0
         call get_star_ptr(id, s, ierr)
         if (ierr /= 0) return

         if (s% dt <= 0d0) then
            do_step_part2 = terminate
            s% termination_code = t_dt_is_zero
            s% result_reason = dt_is_zero
            return
         end if

         time0 = s% starting_system_clock_time
         clock_rate = s% system_clock_rate
         trace = s% trace_evolve
         nz = s% nz

         call setup_for_implicit_mdot_loop
        
      implicit_mdot_loop: do
            
            dt = s% dt
            s% time = s% time_old + dt
            s% okay_to_set_mixing_info = .true.

            if (s% v_center /= 0d0) then ! adjust R_center               
               s% R_center = s% R_center_old + dt*s% v_center
               if (s% R_center < 0d0) then
                  write(*,2) 's% R_center', s% model_number, s% R_center
                  do_step_part2 = retry
                  return
               end if
            end if
      
            call set_vars_if_needed(s, dt, 'start of implicit_mdot_loop', ierr)
            if (failed('set_vars_if_needed start of implicit_mdot_loop')) return

            if (s% RSP_flag) then      
                  
               call set_cgrav(s, ierr)
               if (failed('set_cgrav')) return
                                  
            else

               call do_adjust_mass(s, s% species, ierr)
               if (failed('do_adjust_mass')) return
               call set_vars_if_needed(s, dt, 'after do_adjust_mass', ierr)
               if (failed('set_vars_if_needed after do_adjust_mass')) return

               call calculate_eps_mdot(s, dt, ierr)
               if (failed('calculate_eps_mdot')) return
               
               if (s% mstar_dot /= 0d0) then
                  s% energy_change_from_do_adjust_mass_and_calculate_eps_mdot = &
                     s% total_energy_after_adjust_mass - s% total_energy_before_adjust_mass
               else
                  s% energy_change_from_do_adjust_mass_and_calculate_eps_mdot = 0d0
               end if
               
               call set_vars_if_needed(s, dt, 'after calculate_eps_mdot', ierr)
               if (failed('set_vars_if_needed after calculate_eps_mdot')) return

               if (s% do_conv_premix) then
                  do k=1,s% nz
                     s% eps_pre_mix(k) = s% energy(k)
                  end do
                  call do_conv_premix(s, ierr)
                  if (failed('do_conv_premix')) return
                  call set_vars_if_needed(s, dt, 'after do_conv_premix', ierr)
                  if (failed('set_vars_if_needed after do_conv_premix')) return
                  do k=1,s% nz ! for use by energy equation
                     s% eps_pre_mix(k) = (s% eps_pre_mix(k) - s% energy(k)) / dt
                  end do
               end if

               s% okay_to_set_mixing_info = .false. ! no mixing changes in set_vars after this point
               
               if (s% do_element_diffusion) then
                  call do_element_diffusion(s, dt, ierr)
                  if (failed('do_element_diffusion')) return
                  call set_vars_if_needed(s, dt, 'after element diffusion', ierr)
                  if (failed('set_vars_if_needed after element diffusion')) return
                  call finish_element_diffusion(s,dt) ! calculates eps_diffusion from energy changes                  
                  if (.false.) then
                     write(*,1) 'dt*dm*eps_diffusion/total_energy_old', &
                        dt*dot_product(s% dm(1:s% nz), s% eps_diffusion(1:s% nz))/s% total_energy_old
                  end if
               end if
            
            end if

            if (s% rotation_flag .and. s% premix_omega .and. .not. s% j_rot_flag) then
               do_step_part2 = do_solve_omega_mix(s, 0.5d0*dt)
               if (do_step_part2 /= keep_going) return
               call set_rotation_info(s, .false., ierr)
               if (failed('set_rotation_info')) return
               call set_vars_if_needed(s, dt, 'after do_solve_omega_mix', ierr)
               if (failed('after do_solve_omega_mix')) return
            end if
         
            
            if (s% use_other_pressure) then
               call s% other_pressure(s% id, ierr)
               if (failed('other_pressure returned ierr')) return
            end if
            call set_vars_if_needed(s, dt, 'after other_pressure', ierr)
            if (failed('set_vars_if_needed after other_pressure')) return
            
            call check_for_extra_heat(s, ierr)
            if (failed('check_for_extra_heat')) return
            call set_vars_if_needed(s, dt, 'after check_for_extra_heat', ierr)
            if (failed('set_vars_if_needed after check_for_extra_heat')) return
            
            if (.not. s% have_new_cz_bdy_info) then
               call set_cz_bdy_mass(s, ierr)
               if (failed('set_cz_bdy_mass')) return
            end if
            
            skip_global_corr_coeff_limit = (first_try .or. &
                s% model_number_for_last_retry /= s% model_number) ! last alternative is for redo's

            s% doing_struct_burn_mix = .true.
            do_step_part2 = do_struct_burn_mix( &
               s, skip_global_corr_coeff_limit, dt)
            s% doing_struct_burn_mix = .false.
            if (do_step_part2 /= keep_going) return
            ! when reach here, have taken the step successfully
            ! but might not satisfy the implicit mdot requirements.
            mdot_action = select_mdot_action(ierr)
            if (failed('select_mdot_action')) return
            if (do_step_part2 /= keep_going) return
            if (mdot_action == exit_loop) exit implicit_mdot_loop
            if (s% trace_evolve) write(*,*) 'cycle implicit_mdot_loop'
            
         end do implicit_mdot_loop

         s% solver_iter = 0 ! to indicate that no longer doing solver iterations
         
         if (.not. s% RSP_flag) then
            call set_final_vars(s, dt, ierr)
            if (failed('set_final_vars')) return
         end if

         if (.not. okay_energy_conservation()) return

         if (s% max_timestep_hi_T_limit > 0 .and. &
               s% max_years_for_timestep /= s% hi_T_max_years_for_timestep) then
            if (maxval(s% T(1:nz)) >= s% max_timestep_hi_T_limit) then
               write(*,1) 'switch to high T max timesteps'
               s% max_years_for_timestep = s% hi_T_max_years_for_timestep
               s% max_timestep = secyer*s% max_years_for_timestep
            end if
         end if

         call eval_integrated_total_energy_profile(s, s%total_energy_integral_surface, -1, ierr)
         call eval_integrated_total_energy_profile(s, s%total_energy_integral_center, 1, ierr)

         call set_L_burn_by_category(s) ! final values for use in selecting timestep
         s% total_angular_momentum = total_angular_momentum(s)
         call do_report(s, ierr)
         if (failed('do_report')) return

         call system_clock(time0,clock_rate)
         s% current_system_clock_time = time0
         s% total_elapsed_time = &
            dble(time0 - s% starting_system_clock_time)/dble(clock_rate)
         
         
         contains


         logical function failed(str)
            character (len=*), intent(in) :: str
            if (ierr == 0) then
               failed = .false.
               return
            end if
            failed = .true.
            do_step_part2 = retry
            if (s% report_ierr) write(*, *) 'do_step_part2: ' // trim(str)
            s% result_reason = nonzero_ierr
         end function failed


         subroutine setup_for_implicit_mdot_loop

            ignored_first_step = .false.

            mstar_dot = 0
            w_div_w_crit = -1
            surf_w_div_w_crit_limit = s% surf_w_div_w_crit_limit
            mdot_redo_cnt = 0
            max_mdot_redo_cnt = s% max_mdot_redo_cnt

            max_wind_mdot = 10*Msun/secyer
            have_too_large_wind_mdot = .false.
            have_too_small_wind_mdot = .false.
            too_large_wind_mdot = 0
            too_small_wind_mdot = 0

            explicit_mdot = s% mstar_dot

            was_in_implicit_wind_limit = s% was_in_implicit_wind_limit
            if(abs(s% mstar_dot_old) > 0) then
               if (was_in_implicit_wind_limit .and. &
                   s% generations >= 2 .and. &
                   abs((s% mstar_dot-s% mstar_dot_old)/s% mstar_dot_old)+1 > &
                   s% mdot_revise_factor) then
                   write(*,*) "Skipping first step in implicit mdot"
                   s% mstar_dot = s% mstar_dot_old
                   mdot_redo_cnt = 1
                   ignored_first_step = .true.
               end if
            end if

            abs_mstar_delta = 0
         
            iwind_redo_cnt = 0
            iwind_max_redo_cnt = s% max_tries_for_implicit_wind
            iwind_tolerance = s% iwind_tolerance
            iwind_lambda = s% iwind_lambda         
            
         end subroutine setup_for_implicit_mdot_loop


         integer function select_mdot_action(ierr)
            integer, intent(out) :: ierr
            include 'formats'
            select_mdot_action = exit_loop
            if (s% mstar_dot == 0) return
            if (iwind_redo_cnt < iwind_max_redo_cnt .and. iwind_lambda > 0d0) then
               ! check if mdot calculated at end of step is close enought to what used
               call get_phot_info(s, ph_x, ph_x, ph_x, ph_L, ph_x, ph_x, ph_x, ph_x, ph_x, ph_k)
               call set_mdot(s, ph_L, s% mstar, s% Teff, ierr)
               if (ierr /= 0) then
                  do_step_part2 = retry
                  s% result_reason = nonzero_ierr
                  if (s% report_ierr) write(*, *) 'do_step_part2: set_mdot ierr'
                  return
               end if
               implicit_mdot = s% mstar_dot
               if (abs(explicit_mdot - implicit_mdot) > &
                     abs(implicit_mdot)*iwind_tolerance) then
                  call set_current_to_old(s) ! preparing for redo
                  s% need_to_setvars = .true.
                  s% mstar_dot = explicit_mdot + &
                     iwind_lambda*(implicit_mdot - explicit_mdot)
                  if (.false.) write(*,3) 'implicit mdot: diff/new old new next', &
                     iwind_redo_cnt, s% model_number, &
                     1d0 - explicit_mdot/implicit_mdot, &
                     explicit_mdot, implicit_mdot, s% mstar_dot
                  explicit_mdot = s% mstar_dot
                  do_step_part2 = prepare_for_new_try(s)
                  if (do_step_part2 /= keep_going) return
                  iwind_redo_cnt = iwind_redo_cnt + 1
                  s% need_to_setvars = .true.
                  !cycle implicit_mdot_loop
                  select_mdot_action = cycle_loop
                  return
               end if
               iwind_max_redo_cnt = iwind_redo_cnt ! done with implicit wind
               if (.false.) write(*,3) 'implicit mdot: diff/new old new', &
                  iwind_redo_cnt, s% model_number, &
                  1d0 - explicit_mdot/implicit_mdot, explicit_mdot, implicit_mdot
            end if

            ! check for omega > omega_crit

            if (.not. s% rotation_flag .or. max_mdot_redo_cnt <= 0) then
               !exit implicit_mdot_loop
               select_mdot_action = exit_loop
               return
            end if

            mstar_dot_prev = mstar_dot
            mstar_dot = s% mstar_dot
            wind_mdot = -s% mstar_dot
            
            if (mdot_redo_cnt == 1 .or. ignored_first_step) then
               ! this is the 1st correction to mdot
               r_phot = sqrt(s% L(1)/(pi*crad*clight*pow4(s% Teff)))
               kh_timescale = eval_kh_timescale(s% cgrav(1), s% mstar, r_phot, s% L(1))
               dmskhf = s% rotational_mdot_kh_fac
               dmsfac = s% rotational_mdot_boost_fac
               max_wind_mdot = dmskhf*s% mstar/kh_timescale
               if (wind_mdot > 0) max_wind_mdot = min(max_wind_mdot, wind_mdot*dmsfac)
            end if

            w_div_w_crit_prev = w_div_w_crit
            ! check the new w_div_w_crit to make sure not too large
            call set_surf_avg_rotation_info(s)
            w_div_w_crit = s% w_div_w_crit_avg_surf

            if (wind_mdot >= max_wind_mdot) then
               if (mdot_redo_cnt == 0) then
                  write(*,*) 'cannot fix omega >= omega_crit -- mass loss already at max'
               else
                  write(*,2) 'retry: at max wind mass loss', s% model_number, &
                     log10(max_wind_mdot/(Msun/secyer))
                  do_step_part2 = retry
                  s% result_reason = nonzero_ierr
                  return
               end if
               write(*,*)
               if (w_div_w_crit > surf_w_div_w_crit_limit) then
                  write(*,1) 'retry: w_div_w_crit > surf_w_div_w_crit_limit', &
                     w_div_w_crit, surf_w_div_w_crit_limit
                  do_step_part2 = retry
                  s% result_reason = nonzero_ierr
                  return
               end if
               !exit implicit_mdot_loop
               select_mdot_action = exit_loop
               return
            end if

            ! NOTE: we assume that if surface omega/omega_crit (w_div_w_crit) is too large,
            ! then mass loss needs to be made larger to fix the problem.
            ! if that assumption is wrong,
            ! i.e. if bigger mass loss makes w_div_w_crit worse,
            ! then in an unstable situation and will remove mass until regain stability.

            if (w_div_w_crit <= surf_w_div_w_crit_limit &
                  .and. mdot_redo_cnt == 0) then
               s% was_in_implicit_wind_limit = .false.
               !exit implicit_mdot_loop
               select_mdot_action = exit_loop
               return
            end if

            if (w_div_w_crit <= surf_w_div_w_crit_limit &
                  .and. s% mstar_dot == explicit_mdot) then
               !exit implicit_mdot_loop
               select_mdot_action = exit_loop
               return
               ! implicit scheme reached the limit set by the explicit_mdot;
               ! no problem; no redo required.
            end if

            s% was_in_implicit_wind_limit = .true.

            if (dt/secyer < s% min_years_dt_for_redo_mdot) then
               if (.true.) write(*,1) &
                  'dt too small for fix to fix w > w_crit; min_years_dt_for_redo_mdot', &
                  dt/secyer, s% min_years_dt_for_redo_mdot
               !exit implicit_mdot_loop
               select_mdot_action = exit_loop
               return
            end if

            ! if get here, need to revise mdot to fix w_div_w_crit

            mdot_redo_cnt = mdot_redo_cnt + 1

            if (mdot_redo_cnt == 1) then ! this is the 1st correction to mdot

               call set_current_to_old(s)
               do_step_part2 = prepare_for_new_try(s)
               if (do_step_part2 /= keep_going) return

               have_too_small_wind_mdot = .true.
               too_small_wind_mdot = wind_mdot
               if (s% mstar_dot < 0) then
                  s% mstar_dot = mstar_dot*s% mdot_revise_factor
               else
                  s% mstar_dot = mstar_dot/s% mdot_revise_factor
               end if

               if (-s% mstar_dot > max_wind_mdot) s% mstar_dot = -max_wind_mdot

               write(*,3) 'w > w_crit: revise mdot and redo', &
                  s% model_number, mdot_redo_cnt, w_div_w_crit, &
                  log10(abs(s% mstar_dot)/(Msun/secyer))

               !abs_mstar_delta = max(abs(s% mstar_dot), 1d-6*Msun/secyer)
               abs_mstar_delta = abs(s% mstar_dot)

               s% need_to_setvars = .true.
               !cycle implicit_mdot_loop
               select_mdot_action = cycle_loop
               return

            else if (mdot_redo_cnt == 2 .and. ignored_first_step) then
               abs_mstar_delta = abs(s% mstar_dot_old)
            end if

            ! have already done at least one correction -- check if okay now
            if (w_div_w_crit <= surf_w_div_w_crit_limit .and. &
                  have_too_small_wind_mdot .and. &
                  abs((wind_mdot-too_small_wind_mdot)/wind_mdot) < &
                     s% surf_w_div_w_crit_tol) then
               write(*,3) 'OKAY', s% model_number, mdot_redo_cnt, w_div_w_crit, &
                  log10(abs(s% mstar_dot)/(Msun/secyer))
               write(*,*)
               !exit implicit_mdot_loop ! in bounds so accept it
               select_mdot_action = exit_loop
               return
            end if

            if (mdot_redo_cnt >= max_mdot_redo_cnt) then
               if (max_mdot_redo_cnt > 0) then
                  write(*,3) 'failed to fix w > w_crit: too many tries', &
                     s% model_number, mdot_redo_cnt, w_div_w_crit, &
                     log10(abs(s% mstar_dot)/(Msun/secyer))
                  do_step_part2 = retry
                  s% result_reason = nonzero_ierr
                  return
               end if
               !exit implicit_mdot_loop
               select_mdot_action = exit_loop
               return
            end if

            if (w_div_w_crit > surf_w_div_w_crit_limit &
                  .and. w_div_w_crit_prev >= surf_w_div_w_crit_limit &
                  .and. -mstar_dot >= max_wind_mdot) then
               write(*,3) 'failed to fix w > w_crit', &
                  s% model_number, mdot_redo_cnt, w_div_w_crit, &
                  log10(abs(s% mstar_dot)/(Msun/secyer))
               write(*,*)
               do_step_part2 = retry
               s% result_reason = nonzero_ierr
               return
            end if

            if (w_div_w_crit >= surf_w_div_w_crit_limit) then ! wind too small
               !write(*,*) "entering too small wind mdot"
               if (.not. have_too_small_wind_mdot) then
                  !write(*,*) "setting too small wind mdot"
                  too_small_wind_mdot = wind_mdot
                  have_too_small_wind_mdot = .true.
               else if (wind_mdot > too_small_wind_mdot) then
                  !write(*,*) "changing too small wind mdot"
                  too_small_wind_mdot = wind_mdot
               end if
            else if (w_div_w_crit < surf_w_div_w_crit_limit) then ! wind too large
               !write(*,*) "entering too large wind mdot"
               if (.not. have_too_large_wind_mdot) then
                  !write(*,*) "setting too large wind mdot"
                  too_large_wind_mdot = wind_mdot
                  have_too_large_wind_mdot = .true.
               else if (wind_mdot < too_large_wind_mdot) then
                  !write(*,*) "changing too large wind mdot"
                  too_large_wind_mdot = wind_mdot
               end if
            end if

            call set_current_to_old(s)
            s% need_to_setvars = .true.
            do_step_part2 = prepare_for_new_try(s)
            if (do_step_part2 /= keep_going) return

            if (have_too_large_wind_mdot .and. have_too_small_wind_mdot) then
               if (abs((too_large_wind_mdot-too_small_wind_mdot)/too_large_wind_mdot) &
                   < s% surf_w_div_w_crit_tol) then
                  write(*,*) "too_large_wind_mdot good enough, using it"
                  s% mstar_dot = -too_large_wind_mdot
               else
                  ! have bracketing mdots; bisect for next one.
                  s% mstar_dot = -0.5d0*(too_large_wind_mdot + too_small_wind_mdot)
                  write(*,3) 'fix w > w_crit: bisect mdots and redo', &
                     s% model_number, mdot_redo_cnt, w_div_w_crit, &
                     log10(abs(s% mstar_dot)/(Msun/secyer)), &
                     log10(abs(too_large_wind_mdot)/(Msun/secyer)), &
                     log10(abs(too_small_wind_mdot)/(Msun/secyer))
               end if

            else ! still have wind too small so boost it again
               if (have_too_small_wind_mdot) then
                  if (mod(mdot_redo_cnt,2) == 1) then
                     boost = s% implicit_mdot_boost
                     ! increase mass loss
                     mstar_dot_nxt = mstar_dot - boost*abs_mstar_delta
                  else
                     if (mstar_dot < 0) then ! increase mass loss
                        mstar_dot_nxt = mstar_dot*s% mdot_revise_factor
                     else ! decrease mass gain
                        mstar_dot_nxt = mstar_dot/s% mdot_revise_factor
                     end if
                  end if
               else
                  if (mod(mdot_redo_cnt,2) == 1) then
                     boost = s% implicit_mdot_boost
                     ! decrease mass loss
                     mstar_dot_nxt = mstar_dot + boost*abs_mstar_delta
                  else
                     if (mstar_dot < 0) then ! decrease mass loss
                        mstar_dot_nxt = mstar_dot/s% mdot_revise_factor
                     else ! increase mass gain
                        mstar_dot_nxt = mstar_dot*s% mdot_revise_factor
                     end if
                  end if
               end if
               if (mstar_dot_prev /= explicit_mdot) &
                  mstar_dot_nxt = min(mstar_dot_nxt, explicit_mdot)
               if (mstar_dot_nxt == explicit_mdot) &
                  write(*,*) "implicit mdot: reached explicit_mdot"
               s% mstar_dot = mstar_dot_nxt
               if (-s% mstar_dot > max_wind_mdot) s% mstar_dot = -max_wind_mdot
               !abs_mstar_delta = max(abs_mstar_delta, abs(s% mstar_dot))
               write(*,3) 'fix w > w_crit: change mdot and redo', &
                  s% model_number, mdot_redo_cnt, w_div_w_crit, &
                  log10(abs(s% mstar_dot)/(Msun/secyer))
            end if

            select_mdot_action = cycle_loop ! cycle

         end function select_mdot_action


         subroutine show_debug
            integer :: k
            real(dp) :: alfa, beta, gamma1, Cv, chiRho, chiT, Cp, grada, &
               Pgas, Prad, P, opacity
            include 'formats'
            k = 1205

            alfa = s% dq(k-1)/(s% dq(k-1) + s% dq(k))
            beta = 1 - alfa

            gamma1 = alfa*s% gamma1(k) + beta*s% gamma1(k-1)
            Cv = alfa*s% Cv(k) + beta*s% Cv(k-1)
            chiRho = alfa*s% chiRho(k) + beta*s% chiRho(k-1)
            chiT = alfa*s% chiT(k) + beta*s% chiT(k-1)
            Cp = alfa*s% Cp(k) + beta*s% Cp(k-1)
            grada = alfa*s% grada(k) + beta*s% grada(k-1)
            Pgas = alfa*s% Pgas(k) + beta*s% Pgas(k-1)
            Prad = alfa*s% Prad(k) + beta*s% Prad(k-1)
            P = alfa*s% P(k) + beta*s% P(k-1)
            opacity = alfa*s% opacity(k) + beta*s% opacity(k-1)

            write(*,2) 'at end of step', s% model_number
            write(*,2) 'gamma1', k, gamma1
            write(*,2) 'Cv', k, Cv
            write(*,2) 'chiRho', k, chiRho
            write(*,2) 'chiT', k, chiT
            write(*,2) 'Cp', k, Cp
            write(*,2) 'grada', k, grada
            write(*,2) 'Pgas', k, Pgas
            write(*,2) 'Prad', k, Prad
            write(*,2) 'P', k, P
            write(*,2) 'opacity', k, opacity
            write(*,2) 'L', k, s% L(k)
            write(*,2) 'gradr', k, s% gradr(k)
            write(*,2) 'gradr/grada', k, s% gradr(k)/grada
            write(*,3) 'mixing_type', k, s% mixing_type(k)
            write(*,*)

         end subroutine show_debug


         logical function okay_energy_conservation()
            use rsp, only: rsp_total_energy_integrals
            integer :: nz, k, ierr
            real(dp) :: phase1_sources_and_sinks, phase2_sources_and_sinks, phase2_work, &
               phase1_total_energy_from_mdot, phase2_total_energy_from_mdot, &
               expected_sum_cell_others, expected_sum_cell_sources, &
               diff_total_gravitational_energy, diff_total_internal_energy, diff_total_kinetic_energy, &
               diff_total_rotational_kinetic_energy, diff_total_turbulent_energy, &
               virial, total_radiation, L_surf, sum_cell_de, sum_cell_dEturb, &
               sum_cell_dke, sum_cell_dpe, sum_cell_dL, sum_cell_ergs_error, sum_cell_others, &
               sum_cell_sources, sum_cell_terms, sum_cell_work, total_energy_from_pre_mixing
               
            include 'formats'



!   phase1 := from end of previous step until start of solver
!   phase2 := from start of solver to end of step
!
!   total_energy_old = at beginning of phase1
!   total_energy_start = at beginning of phase2
!   total_energy_end = at end of phase2
!
!   phase1_energy_error = total_energy_start - (total_energy_old + phase1_sources_and_sinks)
!   phase2_energy_error = total_energy_end - (total_energy_start + phase2_sources_and_sinks)
!
!   total_energy_sources_and_sinks = phase1_sources_and_sinks + phase2_sources_and_sinks
!
!   error_in_energy_conservation = total_energy_end - (total_energy_old + total_energy_sources_and_sinks)
!
!   equivalently, error_in_energy_conservation = phase1_energy_error + phase2_energy_error




            okay_energy_conservation = .false.

            nz = s% nz
            if (s% RSP_flag) then
               call rsp_total_energy_integrals(s, &
                  s% total_internal_energy_end, &
                  s% total_gravitational_energy_end, &
                  s% total_radial_kinetic_energy_end, &
                  s% total_rotational_kinetic_energy_end, &
                  s% total_turbulent_energy_end, &
                  s% total_energy_end, total_radiation)
               if (s% RSP_just_set_velocities) then ! reset everything when 1st set velocities
                  s% total_internal_energy_old = s% total_internal_energy_end
                  s% total_gravitational_energy_old = s% total_gravitational_energy_end
                  s% total_radial_kinetic_energy_old = s% total_radial_kinetic_energy_end
                  s% total_rotational_kinetic_energy_old = s% total_rotational_kinetic_energy_end
                  s% total_turbulent_energy_old = s% total_turbulent_energy_end
                  s% total_energy_old = s% total_energy_end
                  total_radiation = 0d0
               end if
            else
               call eval_total_energy_integrals(s, &
                  s% total_internal_energy_end, &
                  s% total_gravitational_energy_end, &
                  s% total_radial_kinetic_energy_end, &
                  s% total_rotational_kinetic_energy_end, &
                  s% total_turbulent_energy_end, &
                  s% total_energy_end)
            end if
               
            if (s% mstar_dot == 0d0) then
               s% total_energy_change_from_mdot = 0d0
               s% total_eps_mdot = 0d0
            else 
               s% total_energy_change_from_mdot = &
                  s% mstar_dot*dt*s% surface_cell_specific_total_energy_old
               s% total_eps_mdot = dt*dot_product(s% dm(1:nz), s% eps_mdot(1:nz))
            end if
               
            virial = 3*sum(s% dm(1:nz)*s% P(1:nz)/s% rho(1:nz))
            s% virial_thm_P_avg = virial

            if (s% u_flag) then ! .or. s% use_dedt_form_of_energy_eqn) then
               s% total_eps_grav = 0
            else
               s% total_eps_grav = dt*dot_product(s% dm(1:nz), s% eps_grav(1:nz))
            end if

            ! When there are mass changes the total energy of the model changes.
            ! We can split this change into three parts:
            ! 1. Mass flows into or out of the model with some specific energy.
            ! 2. There is work done at the surface of the model by pushing material past the pressure of the surface face.
            ! 3. The mass in the model changes state. Near the surface matter changes to maintain the same rho(q) and T(q).
            !    Below the surface regions there is a transition region where the state interpolates between fixed-m and fixed-q.
            !    Still deeper the state is approximately maintained at fixed rho(m), T(m).
            ! 
            ! Change (1) is accounted for entirely by the term s% total_energy_change_from_mdot.
            ! Change (2) is accounted for entirely by the term s% mdot_acoustic_surface.
            !
            ! Change (3) is accounted for by the term eps_mdot in the energy equation and the term
            ! mdot_adiabatic_surface in the energy accounting.
            !
            ! The eps_mdot term accounts for the energy required to change the state of the matter
            ! from its state before adjust_mass to its state after adjust_mass. Matter not present in the
            ! model before adjust_mass is assumed to be in the same state as the surface cell, or else in the
            ! state specified by the other_accreting_surface hook (if used). Matter not present in the model
            ! after adjust_mass is in a state calculated by comparing the thermal and mass-loss time-scales,
            ! and differences between this and the surface state are accounted for by the term mdot_adiabatic_surface.
            ! 
            ! By adding eps_mdot, we cause a change in energy during the Newton iterations which
            ! cancels the change in (3). Thus eps_mdot does not enter into the energy *accounting*, just into
            ! the energy equation. A consequence of this is that the sum
            !
            ! total_energy_change_from_mdot + (total energy before adjust_mass) + mdot_acoustic_surface
            !
            ! does not equal the total energy *after* adjust_mass and *before* the Newton iterations.
            ! However it should equal the total energy at the end of the step.



            if (s% rotation_flag .and. &
                  (s% use_other_torque .or. s% use_other_torque_implicit .or. &
                     associated(s% binary_other_torque))) then
               ! keep track of rotational kinetic energy
            end if
            
            if (s% eps_nuc_factor == 0d0 .or. &
                s% nonlocal_NiCo_decay_heat .or. s% gamma_law_hydro > 0) then
               s% total_nuclear_heating = 0d0
            else if (s% op_split_burn) then
               s% total_nuclear_heating = 0d0
               do k = 1, nz
                  if (s% T_start(k) >= s% op_split_burn_min_T) then
                     s% total_nuclear_heating = s% total_nuclear_heating + &
                        dt*s% dm(k)*s% burn_avg_epsnuc(k)
                  else
                     s% total_nuclear_heating = s% total_nuclear_heating + &
                        dt*s% dm(k)*s% eps_nuc(k)
                  end if
               end do
            else
               s% total_nuclear_heating = dt*dot_product(s% dm(1:nz), s% eps_nuc(1:nz))
            end if
            
            if (s% RSP_flag .or. s% gamma_law_hydro > 0) then
               s% total_non_nuc_neu_cooling = 0d0
               s% total_irradiation_heating = 0d0
            else
               s% total_non_nuc_neu_cooling = dt*0.5d0* &
                  sum((s% non_nuc_neu(1:nz) + s% non_nuc_neu_start(1:nz))*s% dm(1:nz))
               s% total_irradiation_heating = &
                  dt*dot_product(s% dm(1:nz), s% irradiation_heat(1:nz))
            end if
            
            s% total_WD_sedimentation_heating = 0d0
            if (s% do_element_diffusion .and. s% do_WD_sedimentation_heating) then
               s% total_WD_sedimentation_heating = &
                  dt*dot_product(s% dm(1:nz), s% eps_WD_sedimentation(1:nz))
            end if
            
            s% total_energy_from_diffusion = 0d0
            if (s% do_element_diffusion .and. s% do_diffusion_heating) then
               s% total_energy_from_diffusion = &
                  dt*dot_product(s% dm(1:nz), s% eps_diffusion(1:nz))
            end if
            
            total_energy_from_pre_mixing = 0d0
            if (s% do_conv_premix) then
               total_energy_from_pre_mixing = &
                  dt*dot_product(s% dm(1:nz), s% eps_pre_mix(1:nz))
            end if
            
            phase2_total_energy_from_mdot = &
               dt*dot_product(s% dm(1:nz), s% eps_mdot(1:nz))
            
            s% total_extra_heating = dt*dot_product(s% dm(1:nz), s% extra_heat(1:nz))
            
            if (s% u_flag) then ! ignore total_work for Riemann hydro
               s% work_outward_at_surface = 0d0
               s% work_inward_at_center = 0d0
            else ! these are set in energy equation
            end if

            phase2_work = dt*(s% work_outward_at_surface - s% work_inward_at_center)
            
            if (.not. s% RSP_flag) then
               if (s% using_Fraley_time_centering .and. &
                     s% include_L_in_Fraley_time_centering) then
                  L_surf = 0.5d0*(s% L(1) + s% L_start(1))
               else
                  L_surf = s% L(1)
               end if
               total_radiation = dt*(L_surf - s% L_center)
            end if

            !phase1_total_energy_from_mdot = &
            !     s% mdot_acoustic_surface &
            !   + s% total_energy_change_from_mdot &
            !   + s% mdot_adiabatic_surface &
            !   - phase2_total_energy_from_mdot
               
            phase1_total_energy_from_mdot = &
                 s% energy_change_from_do_adjust_mass_and_calculate_eps_mdot &
               + s% mdot_adiabatic_surface ! ??

            phase1_sources_and_sinks = &
                 phase1_total_energy_from_mdot &
               + total_energy_from_pre_mixing &
               + s% total_WD_sedimentation_heating &
               + s% total_energy_from_diffusion &
               + s% non_epsnuc_energy_change_from_split_burn

            phase2_sources_and_sinks = &
               - total_energy_from_pre_mixing &
               - s% total_WD_sedimentation_heating &
               - s% total_energy_from_diffusion &
               + phase2_total_energy_from_mdot &
               + s% total_nuclear_heating &
               - s% total_non_nuc_neu_cooling &
               + s% total_irradiation_heating &
               + s% total_extra_heating &
               - total_radiation & 
               - phase2_work

            s% total_energy_sources_and_sinks = &
               phase1_sources_and_sinks + phase2_sources_and_sinks

            s% error_in_energy_conservation = &
               s% total_energy_end - (s% total_energy_old + s% total_energy_sources_and_sinks)

            s% cumulative_energy_error = s% cumulative_energy_error_old + &
               s% error_in_energy_conservation

         
            if (s% model_number == s% energy_conservation_dump_model_number &
                  .and. .not. s% doing_relax) then

               write(*,*)
               write(*,2) 's% error_in_energy_conservation', s% model_number, s% error_in_energy_conservation
               write(*,2) 'total_energy', s% model_number, s% total_energy
               write(*,2) 'rel_E_err = error/total_energy', s% model_number, s% error_in_energy_conservation/s% total_energy
               write(*,2) 'rel err phase1', s% model_number, &
                  (s% total_energy_start - (s% total_energy_old + phase1_sources_and_sinks))/s% total_energy
               write(*,2) 'rel err phase2', s% model_number, &
                  (s% total_energy_end - (s% total_energy_start + phase2_sources_and_sinks))/s% total_energy
               write(*,*)
               write(*,2) 's% total_energy_old', s% model_number, s% total_energy_old
               write(*,2) 's% total_energy_start', s% model_number, s% total_energy_start
               write(*,2) 's% total_energy_end', s% model_number, s% total_energy_end
               write(*,2) 's% total_energy_sources_and_sinks', s% model_number, s% total_energy_sources_and_sinks
               write(*,*)
               
               if (s% use_dedt_form_with_total_energy_conservation .and. &
                   s% always_use_dedt_form_of_energy_eqn .and. &
                   .not. s% u_flag) then
                  
                  write(*,*)
                  write(*,*) 'for debugging phase1_sources_and_sinks'
                  write(*,*)
                  write(*,2) 'total_energy_from_pre_mixing', s% model_number, total_energy_from_pre_mixing
                  write(*,2) 's% total_WD_sedimentation_heating', s% model_number, s% total_WD_sedimentation_heating
                  write(*,2) 's% total_energy_from_diffusion', s% model_number, s% total_energy_from_diffusion
                  write(*,2) 's% non_epsnuc_energy_change_from_split_burn', s% model_number, s% non_epsnuc_energy_change_from_split_burn
                  write(*,2) 'phase2 sum cell dt*dm*eps_mdot', s% model_number, phase2_total_energy_from_mdot
                  write(*,2) 'phase1_total_energy_from_mdot', s% model_number, phase1_total_energy_from_mdot
                  write(*,2) 'from_do_adjust_mass_and_eps_mdot', s% model_number, &
                     s% energy_change_from_do_adjust_mass_and_calculate_eps_mdot
                  write(*,2) 's% mdot_acoustic_surface', s% model_number, s% mdot_acoustic_surface
                  write(*,2) 's% mdot_adiabatic_surface', s% model_number, s% mdot_adiabatic_surface
                  write(*,2) 'phase2_total_energy_from_mdot', s% model_number, phase2_total_energy_from_mdot

                  write(*,*)
                  write(*,2) 's% mdot_acoustic_surface', s% model_number, s% mdot_acoustic_surface
                  write(*,2) 's% mdot_adiabatic_surface', s% model_number, s% mdot_adiabatic_surface
                  write(*,2) 's% total_energy_change_from_mdot', s% model_number, s% total_energy_change_from_mdot
                  write(*,2) 'phase1_sources_and_sinks', s% model_number, phase1_sources_and_sinks
                  write(*,*) 
                  write(*,2) 'energy_start - energy_old', s% model_number, s% total_energy_start - s% total_energy_old
                  write(*,2) 'err phase1_sources_and_sinks', s% model_number, &
                      s% total_energy_start - (s% total_energy_old + phase1_sources_and_sinks)
                  write(*,2) 'rel err phase1_sources_and_sinks', s% model_number, &
                     (s% total_energy_start - (s% total_energy_old + phase1_sources_and_sinks))/s% total_energy
                  write(*,*)
                  write(*,*)
                  
                  
                  
                  write(*,*) 'for debugging phase2_sources_and_sinks'
                  write(*,*)
                  
                  write(*,2) 's% total_nuclear_heating', s% model_number, s% total_nuclear_heating
                  write(*,2) 's% total_non_nuc_neu_cooling', s% model_number, s% total_non_nuc_neu_cooling
                  write(*,2) 's% total_irradiation_heating', s% model_number, s% total_irradiation_heating
                  write(*,2) 's% total_extra_heating', s% model_number, s% total_extra_heating
                  write(*,*)
                  write(*,2) 'total_energy_from_pre_mixing', s% model_number, total_energy_from_pre_mixing
                  write(*,2) 's% total_WD_sedimentation_heating', s% model_number, s% total_WD_sedimentation_heating
                  write(*,2) 's% total_energy_from_diffusion', s% model_number, s% total_energy_from_diffusion
                  write(*,*)
                  write(*,2) 's% total_energy_change_from_mdot', s% model_number, s% total_energy_change_from_mdot
                  write(*,2) 's% mdot_acoustic_surface', s% model_number, s% mdot_acoustic_surface
                  write(*,2) 's% mdot_adiabatic_surface', s% model_number, s% mdot_adiabatic_surface
                 ! write(*,2) 'phase2_total_energy_from_mdot', s% model_number, phase2_total_energy_from_mdot
                  write(*,*)
                  write(*,2) 'phase2_work', s% model_number, phase2_work
                  write(*,2) 'total_radiation', s% model_number, total_radiation
                  write(*,2) 's% non_epsnuc_energy_change_from_split_burn', s% model_number, &
                     s% non_epsnuc_energy_change_from_split_burn 
                  write(*,*)

                  write(*,2) 's% work_outward_at_surface', s% model_number, s% work_outward_at_surface
                  write(*,2) 's% work_inward_at_center', s% model_number, s% work_inward_at_center
                  write(*,2) 'L_surf', s% model_number, L_surf
                  write(*,2) 'L_center', s% model_number, s% L_center
                  write(*,*)
                  
                  
                  
                  
                   
                  sum_cell_dL = dt*dot_product(s% dm(1:nz), s% dL_dm(1:nz))
                  sum_cell_sources = dt*dot_product(s% dm(1:nz), s% energy_sources(1:nz))
                  sum_cell_others = dt*dot_product(s% dm(1:nz), s% energy_others(1:nz))
                  sum_cell_work = dt*dot_product(s% dm(1:nz), s% dwork_dm(1:nz))
                  sum_cell_dEturb = dt*dot_product(s% dm(1:nz), s% dEturb_dt(1:nz))
                  sum_cell_dke = dt*dot_product(s% dm(1:nz), s% dkedt(1:nz))
                  sum_cell_dpe = dt*dot_product(s% dm(1:nz), s% dpedt(1:nz))
                  sum_cell_de = dt*dot_product(s% dm(1:nz), s% dedt(1:nz))
                  sum_cell_terms = &
                     - sum_cell_dL + sum_cell_sources + sum_cell_others - sum_cell_work &
                     - sum_cell_dEturb - sum_cell_dke - sum_cell_dpe - sum_cell_de
                  sum_cell_terms = -sum_cell_terms ! to make it the same sign as sum_cell_ergs_error
                  sum_cell_ergs_error = sum(s% ergs_error(1:nz))
                  
                  expected_sum_cell_others = &
                     - total_energy_from_pre_mixing &
                     - s% total_WD_sedimentation_heating &
                     - s% total_energy_from_diffusion
                  expected_sum_cell_sources = &
                       phase2_total_energy_from_mdot &
                     + s% total_nuclear_heating &
                     - s% total_non_nuc_neu_cooling &
                     + s% total_irradiation_heating &
                     + s% total_extra_heating
                  
                  !write(*,2) 'rel err sum all cell terms', s% model_number, &
                  !   (phase2_sources_and_sinks - &
                  !      (sum_cell_others + sum_cell_sources + sum_cell_dL + sum_cell_work))/s% total_energy
                  write(*,2) 'rel err sum_cell_others', s% model_number, &
                     (sum_cell_others - expected_sum_cell_others)/s% total_energy, &
                     sum_cell_others, expected_sum_cell_others
                  write(*,2) 'rel err sum_cell_sources', s% model_number, &
                     (sum_cell_sources - expected_sum_cell_sources)/s% total_energy, &
                     sum_cell_sources, expected_sum_cell_sources
                  write(*,2) 'rel err sum_cell_dL', s% model_number, &
                     (sum_cell_dL - total_radiation)/s% total_energy, sum_cell_dL, total_radiation
                  write(*,2) 'rel err sum_cell_work', s% model_number, &
                     (sum_cell_work - phase2_work)/s% total_energy, sum_cell_work, phase2_work
                  write(*,*)
                  
                  diff_total_internal_energy = &
                     s% total_internal_energy_end - s% total_internal_energy_start
                  diff_total_gravitational_energy = &
                     s% total_gravitational_energy_end - s% total_gravitational_energy_start
                  diff_total_kinetic_energy = &
                     s% total_radial_kinetic_energy_end - s% total_radial_kinetic_energy_start
                  !diff_total_rotational_kinetic_energy = &
                  !   s% total_rotational_kinetic_energy_end - s% total_rotational_kinetic_energy_start
                  diff_total_turbulent_energy = &
                     s% total_turbulent_energy_end - s% total_turbulent_energy_start
                     
                  write(*,2) 'post split rel err sum_cell_de', s% model_number, &
                     (sum_cell_de - diff_total_internal_energy)/s% total_energy, &
                     sum_cell_de, diff_total_internal_energy
                  write(*,2) 'post split rel err sum_cell_dpe', s% model_number, &
                     (sum_cell_dpe - diff_total_gravitational_energy)/s% total_energy, &
                     sum_cell_dpe, diff_total_gravitational_energy
                  write(*,2) 'post split rel err sum_cell_dke', s% model_number, &
                     (sum_cell_dke - diff_total_kinetic_energy)/s% total_energy, &
                     sum_cell_dke, diff_total_kinetic_energy
                  !write(*,2) 'rel err ', s% model_number, &
                  !   ( - diff_total_rotational_kinetic_energy)/s% total_energy, &
                  !   , diff_total_rotational_kinetic_energy
                  write(*,2) 'rel err sum_cell_dEturb', s% model_number, &
                     (sum_cell_dEturb - diff_total_turbulent_energy)/s% total_energy, &
                     sum_cell_dEturb, diff_total_turbulent_energy
                  write(*,*)
                     
                     
                  write(*,2) 'expected rel sum_cell_ergs_error', s% model_number, &
                     sum_cell_ergs_error/s% total_energy, &
                     sum_cell_ergs_error, s% total_energy
                  write(*,2) 'actual rel err phase2_sources_and_sinks', s% model_number, &
                     (s% total_energy_end - (s% total_energy_start + phase2_sources_and_sinks))/s% total_energy
                  write(*,2) 'actual/expected', s% model_number, &
                     (s% total_energy_end - (s% total_energy_start + phase2_sources_and_sinks))/sum_cell_ergs_error
                  write(*,2) 'total rel_E_err', s% model_number, &
                     s% error_in_energy_conservation/s% total_energy, &
                     s% error_in_energy_conservation, s% total_energy
                  write(*,*)
               end if
               
               stop 'okay_energy_conservation'

            end if


            if (is_bad_num(s% error_in_energy_conservation)) then
               write(*,2) 's% error_in_energy_conservation', &
                  s% model_number, s% error_in_energy_conservation
               write(*,2) 's% total_energy_end', &
                  s% model_number, s% total_energy_end
               write(*,2) 's% total_energy_change_from_mdot', &
                  s% model_number, s% total_energy_change_from_mdot
               write(*,2) 's% total_energy_start', &
                  s% model_number, s% total_energy_start
               write(*,2) 's% total_energy_sources_and_sinks', &
                  s% model_number, s% total_energy_sources_and_sinks
               write(*,2) 's% total_nuclear_heating', s% model_number, s% total_nuclear_heating
               write(*,2) 's% total_non_nuc_neu_cooling', s% model_number, s% total_non_nuc_neu_cooling
               write(*,2) 's% total_irradiation_heating', s% model_number, s% total_irradiation_heating
               write(*,2) 's% total_extra_heating', s% model_number, s% total_extra_heating
               write(*,2) 'dt*L_surf', s% model_number, dt*L_surf
               write(*,2) 'dt*L_center', s% model_number, dt*s% L_center
               write(*,2) 'L_surf', s% model_number, L_surf
               write(*,2) 's% Fr(1)', s% model_number, s% Fr(1)
               write(*,2) 's% Lc(1)', s% model_number, s% Lc(1)
               write(*,2) 's% Lt(1)', s% model_number, s% Lt(1)
               write(*,2) 'sum L', s% model_number, s% Fr(1)*4d0*pi*s% r(1)*s% r(1)+s% Lc(1)+s% Lt(1)
               okay_energy_conservation = .false.
               stop 'okay_energy_conservation'
               return
            end if
                                    
            if (is_bad_num(s% cumulative_energy_error)) then
               write(*,2) 's% cumulative_energy_error', &
                  s% model_number, s% cumulative_energy_error
               write(*,2) 's% cumulative_energy_error_old', &
                  s% model_number, s% cumulative_energy_error_old
               write(*,2) 's% error_in_energy_conservation', &
                  s% model_number, s% error_in_energy_conservation
               write(*,2) 's% total_energy_sources_and_sinks', &
                  s% model_number, s% total_energy_sources_and_sinks
               write(*,2) 's% total_nuclear_heating', s% model_number, s% total_nuclear_heating
               write(*,2) 's% total_non_nuc_neu_cooling', s% model_number, s% total_non_nuc_neu_cooling
               write(*,2) 's% total_irradiation_heating', s% model_number, s% total_irradiation_heating
               write(*,2) 's% total_extra_heating', s% model_number, s% total_extra_heating
               write(*,2) 's% work_inward_at_center', s% model_number, s% work_inward_at_center
               write(*,2) 's% work_outward_at_surface', s% model_number, s% work_outward_at_surface
               write(*,2) 's% L_center', s% model_number, s% L_center
               okay_energy_conservation = .false.
               stop 'okay_energy_conservation'
               return
            end if

            s% total_internal_energy = s% total_internal_energy_end
            s% total_gravitational_energy = s% total_gravitational_energy_end
            s% total_radial_kinetic_energy = s% total_radial_kinetic_energy_end
            s% total_rotational_kinetic_energy = s% total_rotational_kinetic_energy_end
            s% total_turbulent_energy = s% total_turbulent_energy_end
            s% total_energy = s% total_energy_end

            okay_energy_conservation = .true.

         end function okay_energy_conservation

      end function do_step_part2


      subroutine debug(str, s)
         use chem_def
         character (len=*), intent(in) :: str
         type(star_info), pointer :: s
         integer :: k, j
         include 'formats'
         
         return

         if (.not. s% rotation_flag) return
         k = 1
         write(*,3) trim(str) // ' s% omega(k)', k, s% model_number, s% omega(k)
         return
         j = 2
         !do j=1,1 !s% species
            if (.true. .or. s% xa(j,k) > 1d-9) &
               write(*,1) trim(str) // ' xin(net_iso(i' // &
                  trim(chem_isos% name(s% chem_id(j))) // '))= ', &
                  s% xa(j,k), s% abar(k)
         !end do
      end subroutine debug
         

      subroutine check_for_extra_heat(s, ierr)
         use hydro_vars, only: set_vars
         type (star_info), pointer :: s
         integer, intent(out) :: ierr

         real(dp) :: start_time, end_time, left_to_inject, &
            q00, qp1, qmin, qmax, qtop, qbot, extra, dt, &
            target_injection_time, target_injection_ergs, &
            kap_gamma, tau_gamma_sum, expect_to_inject
         integer :: k, nz, k1

         include 'formats'

         ierr = 0
         if (s% use_other_energy_implicit) return

         nz = s% nz
         dt = s% dt
         s% extra_heat(1:nz) = s% extra_power_source
         s% d_extra_heat_dlndm1(1:nz) = 0d0
         s% d_extra_heat_dlnd00(1:nz) = 0d0
         s% d_extra_heat_dlndp1(1:nz) = 0d0
         s% d_extra_heat_dlnTm1(1:nz) = 0d0
         s% d_extra_heat_dlnT00(1:nz) = 0d0
         s% d_extra_heat_dlnTp1(1:nz) = 0d0
         s% d_extra_heat_dlnR00(1:nz) = 0d0
         s% d_extra_heat_dlnRp1(1:nz) = 0d0
         
         if (s% use_other_energy) then
            call s% other_energy(s% id, ierr)
            if (ierr /= 0) then
               if (s% report_ierr) &
                  write(*, *) 'check_for_extra_heat: other_energy returned ierr', ierr
               return
            end if
         else if (s% inject_uniform_extra_heat /= 0) then
            qp1 = 0d0
            qmin = s% min_q_for_uniform_extra_heat
            qmax = s% max_q_for_uniform_extra_heat
            extra = s% inject_uniform_extra_heat
            do k=nz,1,-1
               q00 = s% q(k)
               if (qp1 >= qmin .and. q00 <= qmax) then ! all inside of region
                  s% extra_heat(k) = s% extra_heat(k) + extra
               else
                  qtop = min(q00, qmax)
                  qbot = max(qp1, qmin)
                  if (qtop > qbot) then ! overlaps region
                     s% extra_heat(k) = s% extra_heat(k) + extra*(qtop - qbot)/s% dq(k)
                  end if
               end if
               qp1 = q00
            end do
            s% need_to_setvars = .true.
         else if (s% nonlocal_NiCo_decay_heat) then
            kap_gamma = s% nonlocal_NiCo_kap_gamma
            do k1=1,nz
               tau_gamma_sum = 0
               do k=k1,1,-1 ! move eps_nuc outward from k1 to extra_heat at k
                  tau_gamma_sum = tau_gamma_sum + &
                     kap_gamma*s% dm(k)/(4*pi*s% rmid(k)*s% rmid(k))
                  if (tau_gamma_sum >= s% dtau_gamma_NiCo_decay_heat) then
                     s% extra_heat(k) = s% extra_heat(k) + &
                        s% eps_nuc(k1)*s% dm(k1)/s% dm(k)
                     exit
                  end if
               end do
            end do
            s% need_to_setvars = .true.
         end if

         if (s% inject_until_reach_model_with_total_energy <= s% total_energy_initial &
               .or. dt <= 0d0 .or. s% total_mass_for_inject_extra_ergs_sec <= 0d0) return         

         start_time = s% start_time_for_inject_extra_ergs_sec
         if (s% time < start_time) return

         if (s% duration_for_inject_extra_ergs_sec > 0) then
            end_time = start_time + s% duration_for_inject_extra_ergs_sec
         else
            end_time = s% max_age_in_seconds
         end if
         if (s% time_old > end_time) return
         
         target_injection_ergs = &
            s% inject_until_reach_model_with_total_energy - s% total_energy_initial
         target_injection_time = end_time - start_time
         s% inject_extra_ergs_sec = target_injection_ergs/target_injection_time               
         left_to_inject = &
            s% inject_until_reach_model_with_total_energy - s% total_energy_start
         qp1 = 0d0
         qmin = max(0d0, Msun*s% base_of_inject_extra_ergs_sec - s% M_center)/s% xmstar
         qmax = min(1d0, qmin + Msun*s% total_mass_for_inject_extra_ergs_sec/s% xmstar)
         extra = s% inject_extra_ergs_sec/(s% xmstar*(qmax - qmin))
         if (s% time > end_time .or. s% time_old < start_time) then
            extra = extra*(min(s% time, end_time) - max(s% time_old, start_time))/dt
         end if
         if (left_to_inject < extra*dt*s% xmstar*(qmax - qmin)) then
            extra = left_to_inject/(dt*s% xmstar*(qmax - qmin))
         end if
         do k=nz,1,-1
            q00 = s% q(k)
            if (qp1 >= qmin .and. q00 <= qmax) then ! all inside of region
               s% extra_heat(k) = s% extra_heat(k) + extra
            else
               qtop = min(q00, qmax)
               qbot = max(qp1, qmin)
               if (qtop > qbot) then ! overlaps region
                  s% extra_heat(k) = s% extra_heat(k) + extra*(qtop - qbot)/s% dq(k)
               end if
            end if
            qp1 = q00
         end do
         
      end subroutine check_for_extra_heat


      subroutine set_start_of_step_info(s, str, ierr)
         use report, only: do_report
         use hydro_vars, only: set_vars_if_needed
         use mlt_info, only: set_gradT_excess_alpha
         use solve_hydro, only: set_L_burn_by_category
         use star_utils, only: min_dr_div_cs, save_for_d_dt, &
            total_angular_momentum, eval_Ledd

         type (star_info), pointer :: s
         character (len=*), intent(in) :: str
         integer, intent(out) :: ierr

         logical :: trace
         integer :: nz, k
         real(dp) :: total_radiation

         include 'formats'

         ierr = 0
         trace = s% trace_evolve
         nz = s% nz

         if (.not. s% RSP_flag) then
            call save_for_d_dt(s)
            call set_vars_if_needed(s, s% dt, str, ierr)
            if (failed('set_vars_if_needed')) return            
            s% edv(1:s% species, 1:s% nz) = 0 ! edv is used by do_report
            call set_L_burn_by_category(s)
            s% total_angular_momentum = total_angular_momentum(s)
            call do_report(s, ierr)
            if (failed('do_report ierr')) return     
         end if

         ! save a few things from start of step that will need later
         s% min_dr_div_cs_start = min_dr_div_cs(s,k)
         s% prev_Lmax = maxval(abs(s% L(1:nz)))
         if (s% rotation_flag) then
            s% surf_r_equatorial = s% r_equatorial(1)
         else
            s% surf_r_equatorial = s% r(1)
         end if
         s% starting_T_center = s% T(nz)
         s% surf_opacity = s% opacity(1)
         s% surf_csound = s% csound(1)
         s% surf_rho = s% rho(1)
         s% prev_Ledd = eval_Ledd(s,ierr)
         if (failed('eval_Ledd ierr')) return

         if (s% generations == 1 .or. s% zero_gravity .or. s%dt == 0d0) then
            s% surf_accel_grav_ratio = 0
         else
            s% surf_accel_grav_ratio = &
               (s% v_surf - s% v_surf_old)/(s% dt*s% grav(1))
         end if
         
         if (.not. (s% RSP_flag .or. s% Eturb_flag)) then
            call set_gradT_excess_alpha(s, ierr)
            if (failed('set_gradT_excess_alpha ierr')) return
         end if

         contains

         logical function failed(str)
            character (len=*), intent(in) :: str
            if (ierr == 0) then
               failed = .false.
               return
            end if
            failed = .true.
            if (s% report_ierr) write(*, *) 'set_start_of_step_info: ' // trim(str)
            s% result_reason = nonzero_ierr
         end function failed

      end subroutine set_start_of_step_info


      integer function prepare_for_new_step(s)
         use evolve_support, only: new_generation
         use chem_def

         type (star_info), pointer :: s

         integer :: ierr, k, j, k0_old, k1_old, k0_new, k1_new
         real(dp) :: total_energy, force_timestep_min, delta_E, sum_delta_E, total_radiation
         real(dp), pointer :: energy_profile_after_remesh(:)
         logical :: trace

         include 'formats'

         ierr = 0
         trace = s% trace_evolve

         prepare_for_new_step = keep_going

         if (s% dt_next <= 0) then
            write(*, *) 's% dt_next', s% dt_next
            prepare_for_new_step = terminate
            if ((s% time >= s% max_age*secyer .and. s% max_age > 0) .or. &
                (s% time >= s% max_age_in_seconds .and. s% max_age_in_seconds > 0)) then
               s% result_reason = result_reason_normal
               s% termination_code = t_max_age
            else
               s% result_reason = dt_is_zero
               s% termination_code = t_dt_is_zero
            end if
            return
         end if

         if (s% dt_next < s% min_timestep_limit) then
            write(*, *) 's% dt_next', s% dt_next
            write(*, *) 's% min_timestep_limit', s% min_timestep_limit
            prepare_for_new_step = terminate
            s% termination_code = t_min_timestep_limit
            s% result_reason = timestep_limits
            return
         end if

         if (.not. s% RSP_flag) then ! store mesh info for following step eps_mdot
            do k=1, s% nz
               s% prev_mesh_xa(:,k) = s% xa(:,k)
               s% prev_mesh_xh(:,k) = s% xh(:,k)

               s% prev_mesh_j_rot(k) = s% j_rot(k)
               s% prev_mesh_omega(k) = s% omega(k)
               s% prev_mesh_nu_ST(k) = s% nu_ST(k)
               s% prev_mesh_D_ST(k) = s% D_ST(k)
               s% prev_mesh_D_DSI(k) = s% D_DSI(k)
               s% prev_mesh_D_SH(k) = s% D_SH(k)
               s% prev_mesh_D_SSI(k) = s% D_SSI(k)
               s% prev_mesh_D_ES(k) = s% D_ES(k)
               s% prev_mesh_D_GSF(k) = s% D_GSF(k)
               s% prev_mesh_D_mix(k) = s% D_mix(k)
               s% prev_mesh_dPdr_dRhodr_info(k) = s% dPdr_dRhodr_info(k)
               s% prev_mesh_D_omega(k) = s% D_omega(k)
               s% prev_mesh_am_nu_rot(k) = s% am_nu_rot(k)
               s% prev_mesh_conv_vel(k) = s% conv_vel(k)
               s% prev_mesh_D_smooth(k) = s% D_smooth(k)

               s% prev_mesh_dq(k) = s% dq(k)

               s% prev_mesh_species_or_nvar_hydro_changed = .false.
            end do
            s% prev_mesh_nz = s% nz
         end if
         
         if (s% okay_to_remesh) then
            if (s% rsp_flag .or. .not. s% doing_first_model_of_run) then
               call set_start_of_step_info(s, 'before do_mesh', ierr)
               if (failed('set_start_of_step_info ierr')) return
               prepare_for_new_step = do_mesh(s) ! sets s% need_to_setvars = .true. if changes anything
               if (prepare_for_new_step /= keep_going) return
            end if
         end if
         
         call new_generation(s, ierr)
         if (failed('new_generation ierr')) return
         s% generations = min(max_generations, s% generations+1)

         if ((s% time + s% dt_next) > s% max_age*secyer .and. s% max_age > 0) then
            s% dt_next = max(0d0, s% max_age*secyer - s% time)
            if ( s% dt_next == 0d0 ) then
               write(*,*) 'WARNING: max_age reached'
               write(*,1) 's% max_age*secyer', s% max_age*secyer
               write(*,1) 's% time', s% time
               write(*,1) 's% max_age', s% max_age
            end if
         else if ((s% time + s% dt_next) > s% max_age_in_seconds &
                  .and. s% max_age_in_seconds > 0) then
            s% dt_next = max(0d0, s% max_age_in_seconds - s% time)
         end if
         
         s% dt = s% dt_next
         force_timestep_min = s% force_timestep_min
         if (force_timestep_min == 0) &
            force_timestep_min = secyer*s% force_timestep_min_years
         if (s% dt < force_timestep_min) then
            s% dt = min(s% dt*s% force_timestep_min_factor, force_timestep_min)
            write(*,2) 'force increase in timestep', s% model_number, s% dt
         end if
         s% dt_start = s% dt

         s% retry_cnt = 0
         s% redo_cnt = 0

         s% need_to_save_profiles_now = .false.
         s% need_to_update_history_now = s% doing_first_model_of_run

         contains

         logical function failed(str)
            character (len=*), intent(in) :: str
            if (ierr == 0) then
               failed = .false.
               return
            end if
            failed = .true.
            prepare_for_new_step = terminate
            if (s% report_ierr) write(*, *) 'prepare_for_new_step: ' // trim(str)
            s% result_reason = nonzero_ierr
         end function failed

      end function prepare_for_new_step


      integer function do_mesh(s)
         use adjust_mesh, only: remesh
         use adjust_mesh_split_merge, only: remesh_split_merge
         use star_utils, only: start_time, update_time
         type (star_info), pointer :: s
         integer(8) :: time0, clock_rate
         integer :: ierr, k
         real(dp) :: total
         include 'formats'
         do_mesh = keep_going
         if (.not. s% okay_to_remesh) return
         if (s% restore_mesh_on_retry &
            .and. s% model_number_for_last_retry > s% model_number - s% num_steps_to_hold_mesh_after_retry) return
         s% need_to_setvars = .true.
         if (s% doing_timing) call start_time(s, time0, total)        
         if (s% use_split_merge_amr) then
            do_mesh = remesh_split_merge(s) ! sets s% need_to_setvars = .true. if changes anything
            if (do_mesh /= keep_going .and. s% report_ierr) &
               write(*, *) 'do_mesh: remesh_split_merge failed'
         else if (.not. s% rsp_flag) then
            do_mesh = remesh(s) ! sets s% need_to_setvars = .true. if changes anything
            if (do_mesh /= keep_going .and. s% report_ierr) &
               write(*, *) 'do_mesh: remesh failed'
         end if
         if (s% doing_timing) call update_time(s, time0, total, s% time_remesh)
         if (do_mesh /= keep_going) then
            s% result_reason = adjust_mesh_failed
            return
         end if
      end function do_mesh


      integer function prepare_for_new_try(s)
         ! return keep_going, terminate, or retry
         ! if don't return keep_going, then set result_reason to say why.
         use net_lib, only: clean_up_fractions
         use net, only: get_screening_mode
         use hydro_rotation, only: use_xh_to_update_i_rot

         type (star_info), pointer :: s

         integer :: ierr, i, j, k, nz, nvar, nvar_hydro
         real(dp), parameter :: max_sum_abs = 10d0, xsum_tol = 1d-2
         real(dp) :: r00, r003, rp13, rm13, r_in, r_out, screening
         logical :: okay

         include 'formats'

         ierr = 0
         s% result_reason = result_reason_normal
         s% termination_code = 0
         s% solver_iter = 0
         s% solver_adjust_iter = 0
         
         nvar = s% nvar
         nvar_hydro = s% nvar_hydro
         nz = s% nz
         s% model_number = s% model_number_old + 1

         prepare_for_new_try = keep_going

         s% result_reason = result_reason_normal
         s% model_number = s% model_number_old + 1
         s% termination_code = 0
         s% solver_iter = 0
         s% solver_adjust_iter = 0
         
         if (.not. s% RSP_flag) then
         
            screening = get_screening_mode(s,ierr)
            if (ierr /= 0) then
               write(*,*) 'bad value for screening_mode ' // trim(s% screening_mode)
               prepare_for_new_try = terminate
               s% termination_code = t_failed_prepare_for_new_try
               return
            end if

            ! check dimensions
            if (size(s% xh_old,dim=1) /= nvar_hydro .or. size(s% xh_old,dim=2) < nz) then
               write(*,*) 'bad dimensions for xh_old', size(s% xh_old,dim=1), nvar_hydro, &
                  size(s% xh_old,dim=2), nz
               prepare_for_new_try = terminate
               s% termination_code = t_failed_prepare_for_new_try
               return
            end if
            if (size(s% xa_old,dim=1) /= s% species .or. size(s% xa_old,dim=2) < nz) then
               write(*,*) 'bad dimensions for xa_old', size(s% xa_old,dim=1), s% species, &
                  size(s% xa_old,dim=2), nz
               prepare_for_new_try = terminate
               s% termination_code = t_failed_prepare_for_new_try
               return
            end if
            if (size(s% q_old,dim=1) < nz) then
               write(*,*) 'bad dimensions for q_old', size(s% q_old,dim=1), nz
               prepare_for_new_try = terminate
               s% termination_code = t_failed_prepare_for_new_try
               return
            end if
            if (size(s% dq_old,dim=1) < nz) then
               write(*,*) 'bad dimensions for dq_old', size(s% dq_old,dim=1), nz
               prepare_for_new_try = terminate
               s% termination_code = t_failed_prepare_for_new_try
               return
            end if
            
            ! note that the following are simply copying values as they were when last did set_vars
            ! so do not need to set s% need_to_setvars = .true.

            do k = 1, nz
               do j=1,nvar_hydro
                  s% xh(j,k) = s% xh_old(j,k) ! start from copy of old structure
               end do
               do j=1,s% species
                  s% xa(j,k) = s% xa_old(j,k) ! start from copy of old composition
               end do
               s% q(k) = s% q_old(k) ! start with same q's
               s% dq(k) = s% dq_old(k) ! start with same dq's
            end do
            
            if (s% D_smooth_flag) then
               do k=1,nz
                  s% D_smooth(k) = s% D_smooth_old(k)
               end do
            end if

            call set_m_and_dm(s)
            call set_dm_bar(s, nz, s% dm, s% dm_bar)

            if (s% rotation_flag) then
               okay = .true.
               do k=1,nz
                  s% j_rot(k) = s% j_rot_old(k)
                  s% omega(k) = s% omega_old(k)
                  if (is_bad_num(s% omega(k)) .or. abs(s% omega(k)) > 1d50) then
                     okay = .false.
                     if (s% stop_for_bad_nums) then
                        write(*,2) 's% omega(k)', k, s% omega(k)
                        stop 'prepare_for_new_try'
                     end if
                  end if
                  s% D_omega(k) = s% D_omega_old(k)
                  s% am_nu_rot(k) = s% am_nu_rot_old(k)
               end do
               if (.not. okay) then
                  write(*,2) 'model_number', s% model_number
                  stop 'prepare_for_new_try: bad num omega'
               end if
               call use_xh_to_update_i_rot(s)
               s% total_angular_momentum = total_angular_momentum(s)
            end if

         end if

      end function prepare_for_new_try


      integer function pick_next_timestep(id)
         ! determine what we want for the next timestep
         ! if don't return keep_going, then set result_reason to say why.
         use timestep, only: timestep_controller
         integer, intent(in) :: id
         integer :: ierr
         type (star_info), pointer :: s
         integer :: i, j, n
         real(dp) :: max_timestep, remaining_years, min_max, prev_max_years
         include 'formats'

         pick_next_timestep = terminate
         call get_star_ptr(id, s, ierr)
         if (ierr /= 0) return
         
         if (s% RSP_flag) then
            pick_next_timestep = keep_going
            s% dt_next = s% RSP_dt
            s% dt_next_unclipped = s% dt_next
            s% why_Tlim = Tlim_max_timestep
            return
         end if         
         
         if (s% trace_evolve) write(*,'(/,a)') 'pick_next_timestep'

         if (s% max_years_for_timestep > 0) then
            max_timestep = secyer*s% max_years_for_timestep
            if (s% max_timestep > 0 .and. s% max_timestep < max_timestep) &
               max_timestep = s% max_timestep
         else
            max_timestep = s% max_timestep
         end if

         pick_next_timestep = timestep_controller(s, max_timestep)
         if (pick_next_timestep /= keep_going) then
            if (s% trace_evolve) &
               write(*,*) 'pick_next_timestep: timestep_controller /= keep_going'
            return
         end if

         s% dt_next_unclipped = s% dt_next
               ! write out the unclipped timestep in saved models
         if (s% time < 0 .and. s% time + s% dt_next > 0) then
            s% dt_next = -s% time
         else if ((s% time + s% dt_next) > s% max_age*secyer .and. s% max_age > 0) then
            s% dt_next = max(0d0, s% max_age*secyer - s% time)
         else if ((s% time + s% dt_next) > s% max_age_in_seconds &
                  .and. s% max_age_in_seconds > 0) then
            s% dt_next = max(0d0, s% max_age_in_seconds - s% time)
         else if (s% num_adjusted_dt_steps_before_max_age > 0 .and. &
                  s% max_years_for_timestep > 0) then
            if (s% max_age > 0) then
               remaining_years = s% max_age - s% star_age
            else if (s% max_age_in_seconds > 0) then
               remaining_years = (s% max_age_in_seconds - s% time)/secyer
            else
               remaining_years = 1d99
            end if
            if (s% using_revised_max_yr_dt) &
               s% max_years_for_timestep = s% revised_max_yr_dt
            n = floor(remaining_years/s% max_years_for_timestep + 1d-6)
            j = s% num_adjusted_dt_steps_before_max_age
            if (remaining_years <= s% max_years_for_timestep) then
               s% max_years_for_timestep = remaining_years
               s% using_revised_max_yr_dt = .true.
               s% revised_max_yr_dt = s% max_years_for_timestep
               s% dt_next = s% max_years_for_timestep*secyer
               write(*,3) 'remaining steps and years until max age', &
                  s% model_number, 1, remaining_years
            else if (n <= j) then
               prev_max_years = s% max_years_for_timestep
               i = floor(remaining_years/s% dt_years_for_steps_before_max_age + 1d-6)
               if ((i+1d-9)*s% dt_years_for_steps_before_max_age < remaining_years) then
                  s% max_years_for_timestep = remaining_years/(i+1)
               else
                  s% max_years_for_timestep = remaining_years/i
               end if
               min_max = prev_max_years*s% reduction_factor_for_max_timestep
               if (s% max_years_for_timestep < min_max) &
                  s% max_years_for_timestep = min_max
               if (.not. s% using_revised_max_yr_dt) then
                  s% using_revised_max_yr_dt = .true.
                  write(*,2) 'begin reducing max timestep prior to max age', &
                     s% model_number, remaining_years
               else if (s% revised_max_yr_dt > s% max_years_for_timestep) then
                  write(*,2) 'reducing max timestep prior to max age', &
                     s% model_number, remaining_years
               else if (s% max_years_for_timestep <= &
                     s% dt_years_for_steps_before_max_age) then
                  i = floor(remaining_years/s% max_years_for_timestep + 1d-6)
                  write(*,3) 'remaining steps and years until max age', &
                     s% model_number, i, remaining_years
               else
                  write(*,2) 'remaining_years until max age', &
                     s% model_number, remaining_years
               end if
               s% revised_max_yr_dt = s% max_years_for_timestep
               if (s% dt_next/secyer > s% max_years_for_timestep) &
                  s% dt_next = s% max_years_for_timestep*secyer
            end if

         end if

      end function pick_next_timestep


      integer function prepare_to_redo(id)
         use evolve_support, only: set_current_to_old
         integer, intent(in) :: id
         type (star_info), pointer :: s
         integer :: ierr
         include 'formats'
         ierr = 0
         call get_star_ptr(id, s, ierr)
         if (ierr /= 0) then
            prepare_to_redo = terminate
            return
         end if
         s% redo_cnt = s% redo_cnt + 1
         if (s% redo_limit > 0 .and. s% redo_cnt > s% redo_limit) then
            write(*,2) 'redo_cnt', s% redo_cnt
            write(*,2) 'redo_limit', s% redo_limit
            call report_problems(s, '-- too many redos')
            s% termination_code = t_redo_limit
            prepare_to_redo = terminate
            return
         end if
         prepare_to_redo = keep_going
         if (s% trace_evolve) write(*,'(/,a)') 'prepare_to_redo'         
         call set_current_to_old(s)         
         s% need_to_setvars = .true.
      end function prepare_to_redo


      integer function prepare_to_retry(id)
         use evolve_support, only: set_current_to_old
         integer, intent(in) :: id
         real(dp) :: retry_factor
         type (star_info), pointer :: s
         integer :: ierr, k
         include 'formats'

         call get_star_ptr(id, s, ierr)
         if (ierr /= 0) then
            prepare_to_retry = terminate
            return
         end if
         
         s% need_to_setvars = .true.

         if (s% restore_mesh_on_retry .and. .not. s% RSP_flag) then
            if (.not. s% prev_mesh_species_or_nvar_hydro_changed) then
               do k=1, s% prev_mesh_nz
                  s% xh_old(:,k) = s% prev_mesh_xh(:,k)
                  s% xa_old(:,k) = s% prev_mesh_xa(:,k)
                  s% j_rot_old(k) = s% prev_mesh_j_rot(k)
                  s% omega_old(k) = s% prev_mesh_omega(k)
                  s% nu_ST_old(k) = s% prev_mesh_nu_ST(k)
                  s% D_ST_old(k) = s% prev_mesh_D_ST(k)
                  s% D_DSI_old(k) = s% prev_mesh_D_DSI(k)
                  s% D_SH_old(k) = s% prev_mesh_D_SH(k)
                  s% D_SSI_old(k) = s% prev_mesh_D_SSI(k)
                  s% D_ES_old(k) = s% prev_mesh_D_ES(k)
                  s% D_GSF_old(k) = s% prev_mesh_D_GSF(k)
                  s% D_mix_old(k) = s% prev_mesh_D_mix(k)
                  s% dPdr_dRhodr_info_old(k) = s% prev_mesh_dPdr_dRhodr_info(k)
                  s% D_omega_old(k) = s% prev_mesh_D_omega(k)
                  s% am_nu_rot_old(k) = s% prev_mesh_am_nu_rot(k)
                  s% conv_vel(k) = s% prev_mesh_conv_vel(k)
                  s% D_smooth_old(k) = s% prev_mesh_D_smooth(k)
                  s% dq_old(k) = s% prev_mesh_dq(k)
               end do
               !call normalize_dqs(s% prev_mesh_nz, s% dq_old, ierr)
               !if (ierr /= 0) then
               !   prepare_to_retry = terminate
               !   return
               !end if
               call set_qs(s% prev_mesh_nz, s% q_old, s% dq_old, ierr)
               if (ierr /= 0) then
                  prepare_to_retry = terminate
                  return
               end if
               s% nz_old = s% prev_mesh_nz
            end if
         end if
         
         if (s% trace_evolve) write(*,'(/,a)') 'prepare_to_retry'
         
         s% bad_max_corr_cnt = 0
         s% retry_cnt = s% retry_cnt + 1
         if (s% retry_limit > 0 .and. s% retry_cnt > s% retry_limit) then
            s% dt_start = sqrt(s% dt*s% dt_start)
            prepare_to_retry = terminate
            return
         end if

         prepare_to_retry = keep_going

         retry_factor = s% timestep_factor_for_retries
         s% dt = s% dt*retry_factor
         if (len_trim(s% retry_message) > 0) then
            write(*,'(a, i8)') ' retry: ' // trim(s% retry_message), s% model_number
         else
            write(*,'(a, i8)') ' retry', s% model_number
            !if (.true.) stop 'failed to set retry_message'
         end if
         if (s% report_ierr) &
            write(*,'(a50,2i6,3f16.6)') 'retry log10(dt/yr), log10(dt), retry_factor', &
               s% retry_cnt, s% model_number, log10(s% dt*retry_factor/secyer), &
               log10(s% dt*retry_factor), retry_factor
         if (s% dt <= max(s% min_timestep_limit,0d0)) then
            write(*,1) 'dt', s% dt
            write(*,1) 'min_timestep_limit', s% min_timestep_limit
            call report_problems(s, 'dt < min_timestep_limit')
            prepare_to_retry = terminate
            s% termination_code = t_min_timestep_limit
            s% result_reason = timestep_limits
            return
         end if

         if (s% max_years_for_timestep > 0) &
            s% max_timestep = secyer*s% max_years_for_timestep
         if (s% max_timestep > 0) s% dt = min(s% dt, s% max_timestep)

         call set_current_to_old(s)
         
         s% num_retries = s% num_retries+1
         if (s% num_retries > s% max_number_retries .and. s% max_number_retries >= 0) then
            write(*,2) 'num_retries', s% num_retries
            write(*,2) 'max_number_retries', s% max_number_retries
            call report_problems(s, '-- too many retries')
            s% termination_code = t_max_number_retries
            prepare_to_retry = terminate; return
         end if

         s% model_number_for_last_retry = s% model_number
         if (s% why_Tlim == Tlim_neg_X) then
            s% timestep_hold = s% model_number + &
               max(s% retry_hold, s% neg_mass_fraction_hold)
         else
            s% timestep_hold = s% model_number + s% retry_hold
         end if
         s% why_Tlim = Tlim_retry

      end function prepare_to_retry


      subroutine report_problems(s,str)
         type (star_info), pointer :: s
         character (len=*), intent(in) :: str
         write(*,*)
         write(*,*) 'stopping because of problems ' // trim(str)
         write(*,*)
      end subroutine report_problems


      integer function finish_step( &
            id, do_photo, &
            ierr)
         ! returns keep_going or terminate
         ! if don't return keep_going, then set result_reason to say why.
         use evolve_support, only: output
         use profile, only: do_save_profiles
         use history, only: write_history_info
         use utils_lib, only: free_iounit, number_iounits_allocated
         use alloc, only: size_work_arrays

         integer, intent(in) :: id
         logical, intent(in) :: do_photo ! if true, then save "photo" for restart

         integer, intent(out) :: ierr

         type (star_info), pointer :: s
         integer, parameter :: nvals = 1, n_ivals = 0
         integer :: j, k, nz, &
            current_num_iounits_in_use, prev_num_iounits_in_use
         integer :: ivals(n_ivals)
         real(dp) :: vals(nvals)
         logical :: trace, will_do_photo

         include 'formats'

         finish_step = terminate

         call get_star_ptr(id, s, ierr)
         if (ierr /= 0) return

         nz = s% nz
         trace = s% trace_evolve

         s% h1_czb_mass_prev = s% h1_czb_mass
         prev_num_iounits_in_use = number_iounits_allocated()

         finish_step = keep_going
         s% result_reason = result_reason_normal

         if (s% need_to_save_profiles_now .and. s% write_profiles_flag) then
            call do_save_profiles(s, ierr)
            s% need_to_save_profiles_now = .false.
         end if

         call check(1)

         if (s% need_to_update_history_now .and. s% do_history_file) then

            call write_history_info( &
               s, ierr)
            if (ierr /= 0) then
               finish_step = terminate
               if (s% report_ierr) write(*, *) 'finish_step: write_history_info ierr', ierr
               s% result_reason = nonzero_ierr
               return
            end if
            s% need_to_update_history_now = .false.
         end if

         call check(2)

         will_do_photo = do_photo
         if(s% photo_interval > 0) then
            if(mod(s% model_number, s% photo_interval) == 0) will_do_photo = .true.
         end if
         if(s% solver_save_photo_call_number > 0)then
            if(s% solver_call_number == s% solver_save_photo_call_number - 1) will_do_photo = .true.
        end if

         if (will_do_photo) then

            call output(id, ierr)

            if (ierr /= 0) then
               finish_step = terminate
               if (s% report_ierr) write(*, *) 'finish_step: output ierr', ierr
               s% result_reason = nonzero_ierr
               return
            end if

         end if

         call check(3)

         s% screening_mode_value = -1 ! force a new lookup for next step
         s% doing_first_model_of_run = .false.


         contains


         subroutine check(i)
            integer, intent(in) :: i
            include 'formats'
            !return

            current_num_iounits_in_use = number_iounits_allocated()
            if (current_num_iounits_in_use > 3 .and. &
                  current_num_iounits_in_use > prev_num_iounits_in_use) then
               write(*,2) 's% model_number', s% model_number
               write(*,2) 'prev_num_iounits_in_use', prev_num_iounits_in_use
               write(*,2) 'current_num_iounits_in_use', current_num_iounits_in_use
               write(*,2) 'i', i
               stop 'finish_step'
            end if
            prev_num_iounits_in_use = current_num_iounits_in_use
         end subroutine check


      end function finish_step


      subroutine set_age(id, age, ierr)
         integer, intent(in) :: id
         real(dp), intent(in) :: age
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         call get_star_ptr(id, s, ierr)
         if (ierr /= 0) return
         s% time = age*secyer
         s% star_age = age
         s% profile_age = age
         s% post_he_age = age
      end subroutine set_age



      end module evolve

