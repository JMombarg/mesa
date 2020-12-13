! ***********************************************************************
!
!   Copyright (C) 2011  Bill Paxton
!
!   this file is part of mesa.
!
!   mesa is free software; you can redistribute it and/or modify
!   it under the terms of the gnu general library public license as published
!   by the free software foundation; either version 2 of the license, or
!   (at your option) any later version.
!
!   mesa is distributed in the hope that it will be useful, 
!   but without any warranty; without even the implied warranty of
!   merchantability or fitness for a particular purpose.  see the
!   gnu library general public license for more details.
!
!   you should have received a copy of the gnu library general public license
!   along with this software; if not, write to the free software
!   foundation, inc., 59 temple place, suite 330, boston, ma 02111-1307 usa
!
! ***********************************************************************
 
      module run_star_extras

      use star_lib
      use star_def
      use const_def
      use math_lib
      
      implicit none

      real(dp) :: expected_freq, actual_freq
      integer :: i, l_to_match !, order_to_match

      
      include "test_suite_extras_def.inc"

      
      ! these routines are called by the standard run_star check_model
      contains

      include "test_suite_extras.inc"
      
      
      subroutine extras_controls(id, ierr)
         use astero_def, only: star_astero_procs
         use astero_lib, only: astero_gyre_is_enabled
         integer, intent(in) :: id
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         s% extras_startup => extras_startup
         s% extras_check_model => extras_check_model
         s% extras_finish_step => extras_finish_step
         s% extras_after_evolve => extras_after_evolve
         s% how_many_extra_history_columns => how_many_extra_history_columns
         s% data_for_extra_history_columns => data_for_extra_history_columns
         s% how_many_extra_profile_columns => how_many_extra_profile_columns
         s% data_for_extra_profile_columns => data_for_extra_profile_columns  
         include 'set_star_astero_procs.inc'
         if (astero_gyre_is_enabled) return
         ierr = -1
         write(*,*) 'not using gyre: pretend got ok match for expected frequency.'
      end subroutine extras_controls

      
      subroutine set_my_vars(id, ierr) ! called from star_astero code
         !use astero_search_data, only: include_my_var1_in_chi2, my_var1
         integer, intent(in) :: id
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         ! my_var's are predefined in the simplex_search_data.
         ! this routine's job is to assign those variables to current value in the model.
         ! it is called whenever a new value of chi2 is calculated.
         ! only necessary to set the my_var's you are actually using.
         ierr = 0
         !if (include_my_var1_in_chi2) then
            call star_ptr(id, s, ierr)
            if (ierr /= 0) return
            !my_var1 = s% Teff
         !end if
      end subroutine set_my_vars
      
      
      subroutine will_set_my_param(id, i, new_value, ierr) ! called from star_astero code
         !use astero_search_data, only: vary_my_param1
         integer, intent(in) :: id
         integer, intent(in) :: i ! which of my_param's will be set
         real(dp), intent(in) :: new_value
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         ierr = 0

         ! old value has not yet been changed.
         ! do whatever is necessary for this new value.
         ! i.e. change whatever mesa params you need to adjust.
         ! as example, my_param1 is alpha_mlt
         ! if (i == 1) then
         !    call star_ptr(id, s, ierr)
         !    if (ierr /= 0) return
         !    s% mixing_length_alpha = new_value
         ! end if
      end subroutine will_set_my_param

      
      subroutine extras_startup(id, restart, ierr)
         integer, intent(in) :: id
         logical, intent(in) :: restart
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         call test_suite_startup(s, restart, ierr)
      end subroutine extras_startup
      
      
      subroutine extras_after_evolve(id, ierr)
         integer, intent(in) :: id
         integer, intent(out) :: ierr
         
         type (star_info), pointer :: s
         logical :: okay
         real(dp) :: dt
         
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         
         if (s% x_ctrl(1) > 0d0) then
         
            call get_gyre_frequency_info(s, .true., okay, ierr)
         
            if (ierr /= 0) stop 1
            if (okay) then
               write(*,'(a,2f20.2)') 'got ok match for expected frequency', actual_freq, expected_freq
            else
               write(*,'(a,2f20.2)') 'ERROR: bad match for expected frequency', actual_freq, expected_freq
            end if
            
         end if

         call test_suite_after_evolve(s, ierr)
      end subroutine extras_after_evolve
      

      ! returns either keep_going, retry, or terminate.
      integer function extras_check_model(id)
         use astero_lib, only: astero_gyre_is_enabled
         integer, intent(in) :: id

         type (star_info), pointer :: s
         logical :: okay
         integer :: ierr

         ierr = 0

         if (.not. astero_gyre_is_enabled) then
            extras_check_model = terminate
            return
         end if

         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         
         extras_check_model = keep_going
         
         if (s% x_ctrl(1) > 0d0) then
         
            ! get frequencies for certain models
            if (mod(s% model_number,50) /= 0) return
                  
            write(*,*) 'get gyre frequency info'
         
            call get_gyre_frequency_info(s, .false., okay, ierr)
            if (ierr /= 0) extras_check_model = terminate
            
         end if
         
      end function extras_check_model


      subroutine get_gyre_frequency_info(s, check_match, okay, ierr)
         use astero_lib, only: astero_gyre_get_modes
         use astero_def, only: gyre_input_file, gyre_non_ad, num_results, &
            order, em, inertia, cyclic_freq, growth_rate
         type (star_info), pointer :: s
         logical, intent(in) :: check_match
         logical, intent(out) :: okay
         integer, intent(out) :: ierr
         
         integer :: i, order_to_match
         logical :: store_model
         
         include 'formats'

         ierr = 0
         okay = .false.
         
         ! change the following for your specific case
         l_to_match = 0
         order_to_match = 4
         expected_freq = s% x_ctrl(1)
         
         ! get values for gyre_input_file and gyre_non_ad from the astero controls inlist
         ! store_model must be .true. since this is the 1st call on gyre for this model.
         store_model = .true.
         
         num_results = 0 ! initialize this counter before calling gyre

         call astero_gyre_get_modes( &
            s% id, l_to_match, store_model, ierr)
         if (ierr /= 0) then
            write(*,*) 'failed in do_gyre_get_modes'
            stop 1
         end if
         
         write(*,*)
         write(*,'(2a8,99a20)') 'el', 'order', 'freq (microHz)', 'inertia', 'growth rate (s)'
         do i = 1, num_results
            write(*,'(2i8,f20.10,2e20.10,i20)') l_to_match, order(i), cyclic_freq(i), inertia(i), growth_rate(i)
            if (check_match .and. expected_freq > 0 .and. .not. okay .and. order(i) == order_to_match) then
               actual_freq = cyclic_freq(i)
               okay = (abs(actual_freq - expected_freq) < expected_freq*3d-2)
            end if
         end do

      end subroutine get_gyre_frequency_info


      integer function how_many_extra_history_columns(id)
         integer, intent(in) :: id
         integer :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         how_many_extra_history_columns = 0
      end function how_many_extra_history_columns
      
      
      subroutine data_for_extra_history_columns(id, n, names, vals, ierr)
         integer, intent(in) :: id, n
         character (len=maxlen_history_column_name) :: names(n)
         real(dp) :: vals(n)
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
      end subroutine data_for_extra_history_columns

      
      integer function how_many_extra_profile_columns(id)
         use star_def, only: star_info
         integer, intent(in) :: id
         integer :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         how_many_extra_profile_columns = 0
      end function how_many_extra_profile_columns
      
      
      subroutine data_for_extra_profile_columns(id, n, nz, names, vals, ierr)
         use star_def, only: star_info, maxlen_profile_column_name
         use const_def, only: dp
         integer, intent(in) :: id, n, nz
         character (len=maxlen_profile_column_name) :: names(n)
         real(dp) :: vals(nz,n)
         integer, intent(out) :: ierr
         type (star_info), pointer :: s
         integer :: k
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
      end subroutine data_for_extra_profile_columns
      

      ! returns either keep_going or terminate.
      integer function extras_finish_step(id)
         integer, intent(in) :: id
         integer :: ierr
         type (star_info), pointer :: s
         ierr = 0
         call star_ptr(id, s, ierr)
         if (ierr /= 0) return
         extras_finish_step = keep_going
      end function extras_finish_step
      
      

      end module run_star_extras
      