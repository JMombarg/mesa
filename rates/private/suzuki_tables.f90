module suzuki_tables

  use const_def
  use math_lib
  use utils_lib, only: mesa_error, is_bad, set_nan
  use rates_def

  implicit none

#ifdef USE_HDF5
  integer :: num_suzuki_reactions

  integer, pointer, dimension(:) :: & ! (num_suzuki_reactions)
       suzuki_lhs_nuclide_id, suzuki_rhs_nuclide_id, suzuki_reaclib_id
  character(len=iso_name_length), dimension(:), pointer :: &
       suzuki_lhs_nuclide_name, suzuki_rhs_nuclide_name ! (num_suzuki_reactions)
  type (integer_dict), pointer :: suzuki_reactions_dict

  type(table_c), dimension(:), allocatable :: suzuki_reactions_tables

  type, extends(weak_rate_table) :: suzuki_rate_table

     ! density:  log_{10}(\rho Y_e):
     ! temperature: log_{10}T:
     ! chemical potential:  mu
     ! Coulomb effect parameters:
     !   shift in Q-value:   dQ
     !   shift in chemical potential: Vs
     ! e-capture rate or beta-decay rate:  e-cap-rate:  log_{10}(rate)
     ! neutrino energy-loss rate: nu-energy-loss: log_{10}(rate)
     ! gamma-ray heating rate: gamma-energy: log_{10}(rate)

     integer :: num_T
     real(dp), allocatable :: logTs(:)

     integer :: &
          i_capture_mu = 1, &
          i_capture_dQ = 2, &
          i_capture_Vs = 3, &
          i_capture_rate = 4, &
          i_capture_nu = 5, &
          i_capture_gamma = 6, &
          i_decay_mu = 7, &
          i_decay_dQ = 8, &
          i_decay_Vs = 9, &
          i_decay_rate = 10, &
          i_decay_nu = 11, &
          i_decay_gamma = 12

     logical :: has_decay_data
     logical :: has_capture_data

   contains

     procedure :: setup => setup_suzuki_table
     procedure :: interpolate => interpolate_suzuki_table

  end type suzuki_rate_table

  interface suzuki_rate_table
     module procedure new_suzuki_rate_table
  end interface suzuki_rate_table

contains


  function new_suzuki_rate_table(logTs, lYeRhos)
    real(dp), intent(in), dimension(:) :: logTs, lYeRhos
    type(suzuki_rate_table) :: new_suzuki_rate_table

    new_suzuki_rate_table% num_T = size(logTs)
    allocate(new_suzuki_rate_table% logTs(new_suzuki_rate_table% num_T))
    new_suzuki_rate_table% logTs = logTs

    new_suzuki_rate_table% num_lYeRho = size(lYeRhos)
    allocate(new_suzuki_rate_table% lYeRhos(new_suzuki_rate_table% num_lYeRho))
    new_suzuki_rate_table% lYeRhos = lYeRhos

    allocate(new_suzuki_rate_table% data(1, new_suzuki_rate_table% num_T, new_suzuki_rate_table% num_lYeRho, 12))
  end function new_suzuki_rate_table


  subroutine setup_suzuki_table(table, ierr)
    class(suzuki_rate_table), intent(inout) :: table
    integer, intent(out) :: ierr

    ierr = 0
  end subroutine setup_suzuki_table

  subroutine interpolate_suzuki_table(table, T9, lYeRho, &
       lambda, dlambda_dlnT, dlambda_dlnRho, &
       Qneu, dQneu_dlnT, dQneu_dlnRho, &
       delta_Q, Vs, ierr)
    use const_def, only : dp
    class(suzuki_rate_table), intent(inout) :: table
    real(dp), intent(in) :: T9, lYeRho
    real(dp), intent(out) :: lambda, dlambda_dlnT, dlambda_dlnRho
    real(dp), intent(out) :: Qneu, dQneu_dlnT, dQneu_dlnRho
    real(dp), intent(out) :: delta_Q, Vs
    integer, intent(out) :: ierr

    integer :: ix, jy          ! target cell in the spline data
    real(dp) :: x0, xget, x1      ! x0 <= xget <= x1;  x0 = xs(ix), x1 = xs(ix+1)
    real(dp) :: y0, yget, y1      ! y0 <= yget <= y1;  y0 = ys(jy), y1 = ys(jy+1)

    real(dp) :: logT

    real(dp) :: delta_logT, dlogT, dlYeRho, delta_lYeRho, y_alfa, y_beta, x_alfa, x_beta
    integer :: ilogT, ilYeRho

    real(dp) :: ldecay, d_ldecay_dlogT, d_ldecay_dlYeRho, &
         lcapture, d_lcapture_dlogT, d_lcapture_dlYeRho, &
         ldecay_nu, d_ldecay_nu_dlogT, d_ldecay_nu_dlYeRho, &
         lcapture_nu, d_lcapture_nu_dlogT, d_lcapture_nu_dlYeRho, &
         decay_dQ, d_decay_dQ_dlogT, d_decay_dQ_dlYeRho, &
         capture_dQ, d_capture_dQ_dlogT, d_capture_dQ_dlYeRho, &
         decay_Vs, d_decay_Vs_dlogT, d_decay_Vs_dlYeRho, &
         capture_Vs, d_capture_Vs_dlogT, d_capture_Vs_dlYeRho

    real(dp) :: decay, capture, nu, decay_nu, capture_nu

    logical :: dbg = .false.

    logT = log10(T9) + 9d0

    ! xget = logT
    ! yget = lYeRho

    ierr = 0

    ! clip small values to edge of table
    if (logT < table % logTs(1)) &
         ierr = -1 !return !logT = table % logTs(1)
    if (lYeRho < table % lYeRhos(1)) &
         ierr = -1 !return !lYeRho = table % lYeRhos(1)

    ! clip large values to edge of table
    if (logT > table % logTs(table % num_T)) &
         ierr = -1 !return !logT = table % logTs(table % num_T)
    if (lYeRho > table % lYeRhos(table % num_lYeRho)) &
         ierr = -1 !return !lYeRho = table % lYeRhos(table % num_lYeRho)

    if (ierr /=0) return

    call setup_for_linear_interp

    if (table % has_decay_data) then
       call do_linear_interp( &
            table % data(:,1:table%num_T,1:table%num_lYeRho,table%i_decay_rate), &
            ldecay, d_ldecay_dlogT, d_ldecay_dlYeRho, ierr)
       decay = exp10(ldecay)
    else
       decay = 0d0
       d_ldecay_dlogT = 0d0
       d_ldecay_dlYeRho = 0d0
    end if


    if (table % has_capture_data) then
       call do_linear_interp( &
            table % data(:,1:table%num_T,1:table%num_lYeRho,table%i_capture_rate), &
            lcapture, d_lcapture_dlogT, d_lcapture_dlYeRho, ierr)
       capture = exp10(lcapture)
    else
       capture = 0d0
       d_lcapture_dlogT = 0d0
       d_lcapture_dlYeRho = 0d0
    end if


    ! set lambda
    lambda = decay + capture
    dlambda_dlnT = decay*d_ldecay_dlogT + capture*d_lcapture_dlogT
    dlambda_dlnRho = decay*d_ldecay_dlYeRho + capture*d_lcapture_dlYeRho


    if (table % has_decay_data) then
       call do_linear_interp( &
            table % data(:,1:table%num_T,1:table%num_lYeRho,table%i_decay_nu), &
            ldecay_nu, d_ldecay_nu_dlogT, d_ldecay_nu_dlYeRho, ierr)
       decay_nu = exp10(ldecay_nu)
    else
       decay_nu = 0
       d_ldecay_nu_dlogT = 0
       d_ldecay_nu_dlYeRho = 0
    end if

    if (table % has_capture_data) then
       call do_linear_interp( &
            table % data(:,1:table%num_T,1:table%num_lYeRho,table%i_capture_nu), &
            lcapture_nu, d_lcapture_nu_dlogT, d_lcapture_nu_dlYeRho, ierr)
       capture_nu = exp10(lcapture_nu)
    else
       capture_nu = 0d0
       d_lcapture_nu_dlogT = 0d0
       d_lcapture_nu_dlYeRho = 0d0
    end if


    if (dbg) then
       write(*,*) 'logT', logT
       write(*,*) 'lYeRho', lYeRho
       write(*,*) 'ldecay', ldecay
       write(*,*) 'lcapture', lcapture
       write(*,*) 'lambda', lambda
    end if


    ! set Qneu
    ! be careful; you don't want to get in to the situtation where 1d-99/1d-99 = 1...
    if (lambda .gt. 1d-30) then
       nu = capture_nu + decay_nu
       Qneu = nu / lambda
       dQneu_dlnT = Qneu * ((capture_nu/nu)*d_lcapture_nu_dlogT + (decay_nu/nu)*d_ldecay_nu_dlogT &
            - (capture/lambda)*d_lcapture_dlogT - (decay/lambda)*d_ldecay_dlogT)
       dQneu_dlnRho = Qneu * ((capture_nu/nu)*d_lcapture_nu_dlYeRho + (decay_nu/nu)*d_ldecay_nu_dlYeRho - &
            (capture/lambda)*d_lcapture_dlYeRho - (decay/lambda)*d_ldecay_dlYeRho)
    else
       Qneu = 0d0
       dQneu_dlnT = 0d0
       dQneu_dlnRho = 0d0
    endif

    ! get coulomb corrections

    if (table % has_capture_data) then

       call do_linear_interp( &
            table % data(:,1:table%num_T,1:table%num_lYeRho,table%i_capture_dQ), &
            capture_dQ, d_capture_dQ_dlogT, d_capture_dQ_dlYeRho, ierr)

       call do_linear_interp( &
            table % data(:,1:table%num_T,1:table%num_lYeRho,table%i_capture_Vs), &
            capture_Vs, d_capture_Vs_dlogT, d_capture_Vs_dlYeRho, ierr)

    else

       capture_dQ = 0
       capture_Vs = 0

    end if


    if (table % has_decay_data) then

       call do_linear_interp( &
            table % data(:,1:table%num_T,1:table%num_lYeRho,table%i_decay_dQ), &
            decay_dQ, d_decay_dQ_dlogT, d_decay_dQ_dlYeRho, ierr)

       call do_linear_interp( &
            table % data(:,1:table%num_T,1:table%num_lYeRho,table%i_decay_Vs), &
            decay_Vs, d_decay_Vs_dlogT, d_decay_Vs_dlYeRho, ierr)

    else

       decay_dQ = 0
       decay_Vs = 0

    end if

    ! it is unclear to me why decay_dQ and capture_dQ are different.
    ! if both are defined, we pick the one corresponding to the
    ! process that dominates the rate.

    if ((decay_dQ * capture_dQ) .eq. 0) then
       ! this will be
       !    capture_dQ    if decay_dQ = 0
       !    delta_dQ      if capture_dQ = 0
       delta_Q = (capture_dQ + decay_dQ)
    else
       if (capture .gt. decay) then
          delta_Q = capture_dQ
       else
          delta_Q = decay_dQ
       endif

       ! if they're too different, output an error message
       if (dbg) then
          if (abs((capture_dQ - decay_dQ) / delta_Q) .gt. 0.0d0) then
             write(*,*) 'difference in dQ > 0'
             write(*,*) 'logT', logT
             write(*,*) 'lYeRho', lYeRho
             write(*,*) 'decay_dQ', decay_dQ
             write(*,*) 'capture_dQ', capture_dQ
          end if
       end if
       
    end if

    if ((capture_Vs * decay_Vs) .eq. 0) then
       Vs = (capture_Vs + decay_Vs)
    else
       if (capture .gt. decay) then
          Vs = capture_Vs
       else
          Vs = decay_Vs
       endif
    end if


  contains

    subroutine find_location ! set ix, jy; x is logT; y is lYeRho
      integer i, j
      real(dp) :: del
      include 'formats.dek'
      ! x0 <= logT <= x1
      ix = table % num_T-1 ! since weak_num_logT is small, just do a linear search
      do i = 2, table % num_T-1
         if (logT > table% logTs(i)) cycle
         ix = i-1
         exit
      end do

      ! y0 <= lYeRho <= y1
      jy = table % num_lYeRho-1 ! since weak_num_lYeRho is small, just do a linear search
      do j = 2, table % num_lYeRho-1
         if (lYeRho > table % lYeRhos(j)) cycle
         jy = j-1
         exit
      end do

      x0 = table % logTs(ix)
      x1 = table % logTs(ix+1)
      y0 = table % lYeRhos(jy)
      y1 = table % lYeRhos(jy+1)

    end subroutine find_location

    subroutine setup_for_linear_interp
      include 'formats.dek'

      call find_location

      dlogT = logT - x0
      delta_logT = x1 - x0
      x_beta = dlogT / delta_logT ! fraction of x1 result
      x_alfa = 1 - x_beta ! fraction of x0 result
      if (x_alfa < 0 .or. x_alfa > 1) then
         write(*,1) 'suzuki: x_alfa', x_alfa
         write(*,1) 'logT', logT
         write(*,1) 'x0', x0
         write(*,1) 'x1', x1
         call mesa_error(__FILE__,__LINE__)
      end if

      dlYeRho = lYeRho - y0
      delta_lYeRho = y1 - y0
      y_beta = dlYeRho / delta_lYeRho ! fraction of y1 result
      y_alfa = 1 - y_beta ! fraction of y0 result
      if (is_bad(y_alfa) .or. y_alfa < 0 .or. y_alfa > 1) then
         write(*,1) 'suzuki: y_alfa', y_alfa
         write(*,1) 'logT', logT
         write(*,1) 'x0', x0
         write(*,1) 'dlogT', dlogT
         write(*,1) 'delta_logT', delta_logT
         write(*,1) 'lYeRho', lYeRho
         write(*,1) 'y0', y0
         write(*,1) 'dlYeRho', dlYeRho
         write(*,1) 'y1', y1
         write(*,1) 'delta_lYeRho', delta_lYeRho
         write(*,1) 'y_beta', y_beta
         !stop 'weak setup_for_linear_interp'
      end if

      if (dbg) then
         write(*,2) 'logT', ix, x0, logT, x1
         write(*,2) 'lYeRho', jy, y0, lYeRho, y1
         write(*,1) 'x_alfa, x_beta', x_alfa, x_beta
         write(*,1) 'y_alfa, y_beta', y_alfa, y_beta
         write(*,*)
      end if

    end subroutine setup_for_linear_interp

    subroutine do_linear_interp(f, fval, df_dx, df_dy, ierr)
      use interp_1d_lib
      use utils_lib, only: is_bad
      real(dp), dimension(:,:,:) :: f ! (4, nx, ny)
      real(dp), intent(out) :: fval, df_dx, df_dy
      integer, intent(out) :: ierr

      real(dp) :: fx0, fx1, fy0, fy1

      include 'formats'

      ierr = 0

      fx0 = y_alfa*f(1,ix,jy) + y_beta*f(1,ix,jy+1)
      fx1 = y_alfa*f(1,ix+1,jy) + y_beta*f(1,ix+1,jy+1)

      fy0 = x_alfa*f(1,ix,jy) + x_beta*f(1,ix+1,jy)
      fy1 = x_alfa*f(1,ix,jy+1) + x_beta*f(1,ix+1,jy+1)

      fval = x_alfa*fx0 + x_beta*fx1
      df_dx = (fx1 - fx0)/(x1 - x0)
      df_dy = (fy1 - fy0)/(y1 - y0)

      if (is_bad(fval)) then
         ierr = -1
         return

         write(*,1) 'x_alfa', x_alfa
         write(*,1) 'x_beta', x_beta
         write(*,1) 'fx0', fx0
         write(*,1) 'fx1', fx1
         write(*,1) 'y_alfa', y_alfa
         write(*,1) 'y_beta', y_beta
         write(*,1) 'f(1,ix,jy)', f(1,ix,jy)
         write(*,1) 'f(1,ix,jy+1)', f(1,ix,jy+1)
         !stop 'weak do_linear_interp'
      end if

    end subroutine do_linear_interp

  end subroutine interpolate_suzuki_table


  subroutine private_load_suzuki_tables(ierr)

    use hdf5
    use iso_c_binding

    use utils_lib
    use chem_lib, only: chem_get_iso_id
    use chem_def, only: iso_name_length

    integer, intent(out) :: ierr

    character (len=256) :: filename, cache_filename, string
    character (len=256) :: suzuki_data_dir

    integer(hid_t) :: file_id, group_id

    type(c_funptr) :: funptr
    type(c_ptr) :: ptr
    integer(hsize_t) :: idx
    integer :: ret_value

    integer :: i, storage_type, nlinks, max_corder, attr_num, rxn_idx

    character(len=2*iso_name_length+1) :: key

    logical, parameter :: dbg = .false.

    integer :: num_suzuki_reactions

    if (dbg) write(*,*) 'private_load_suzuki_tables'

    suzuki_data_dir = trim(mesa_data_dir) // '/rates_data'
    filename = trim(suzuki_data_dir) // '/suzuki/Suzuki2016.h5'
    if (dbg) then
       write(*,*)
       write(*,*) 'read filename <' // trim(filename) // '>'
       write(*,*)
    end if

    ! open hdf5 interface
    call h5open_f(ierr)
    if (ierr /= 0) return

    ! open file (read-only)
    call h5fopen_f(filename, h5f_acc_rdonly_f, file_id, ierr)
    if (ierr /= 0) return

    ! open root group and count number of links
    call h5gopen_f(file_id, "/", group_id, ierr)
    call h5gget_info_f(group_id, storage_type, num_suzuki_reactions, max_corder, ierr)
    if (dbg) write(*,*) 'read ', num_suzuki_reactions, ' reactions'

    ! allocate space for all this data
    call alloc
    if (failed('allocate')) return

    ! this next part iterates through the hdf files and loads the data
    nullify(suzuki_reactions_dict)

    idx = 0
    funptr = c_funloc(op_func)
    ptr    = c_null_ptr

    rxn_idx = 0
    call h5literate_f(file_id, h5_index_name_f, h5_iter_native_f, idx, funptr, ptr, ret_value, ierr)

    ! check that we read the right number of reactions
    if (rxn_idx /= num_suzuki_reactions) then
       write(*,*) rxn_idx, num_suzuki_reactions
       call mesa_error(__FILE__, __LINE__)
    end if

    ! close file
    call h5fclose_f(file_id, ierr)
    if (ierr /= 0) return

    ! close interface
    call h5close_f(ierr)
    if (ierr /= 0) return

    ! set up reaction dictionary
    call integer_dict_create_hash(suzuki_reactions_dict, ierr)
    if (failed('integer_dict_create_hash')) return

    ! pre-construct interpolants
    do i = 1, num_suzuki_reactions
       associate(t => suzuki_reactions_tables(i) % t)
         if (ierr == 0) call t% setup(ierr)
       end associate
       if (failed('setup')) return
    end do

    if (dbg) write(*,*) 'finished load_suzuki_tables'


  contains

    ! this function is taken from the example
    integer function op_func(loc_id, name, info, operator_data) bind(C)

      use hdf5
      use iso_c_binding
      use weak_support, only : parse_weak_rate_name

      implicit none

      integer(hid_t), value :: loc_id
      character(len=1), dimension(1:32) :: name ! must have len=1 for bind(C) strings
      type(c_ptr) :: info
      type(c_ptr) :: operator_data

      integer :: status, i, len
      integer :: storage_type, nlinks, max_corder

      type(h5o_info_t), target :: infobuf
      type(c_ptr) :: ptr
      character(len=32) :: name_string

      integer(hid_t) :: group_id, dspace_id, dset_id, subgroup_id

      real(dp), allocatable, dimension(:) :: logTs, lYeRhos
      real(dp), allocatable, dimension(:,:) :: dset_data ! Data buffers

      integer(hsize_t), dimension(2) :: data_dims, max_dims

      type(suzuki_rate_table) :: table

      character(len=32) :: rxn_name
      character(len=iso_name_length) :: lhs, rhs
      character(len=2*iso_name_length+1) :: key


      !
      ! Get type of the object and display its name and type.  The
      ! name of the object is passed to this function by the library.
      !

      do i = 1, 32
         name_string(i:i) = name(i)(1:1)
      enddo

      call h5oget_info_by_name_f(loc_id, name_string, infobuf, status)

      ! Include the string up to the C NULL CHARACTER
      len = 0
      do
         if(name_string(len+1:len+1).eq.c_null_char.or.len.ge.32) exit
         len = len + 1
      enddo

      if(infobuf%type.eq.h5o_type_group_f)then

         if (dbg) write(*,*) "Group: ", name_string(1:len)
         call h5gopen_f(loc_id, name_string(1:len), group_id, ierr)

         rxn_name = "r_" // name_string(1:len)
         call parse_weak_rate_name(rxn_name, lhs, rhs, ierr)
         if (dbg) write(*,*) 'parse_weak_rate_name gives ', trim(lhs), ' ', trim(rhs), ierr

         ! increment rxn_idx
         rxn_idx = rxn_idx + 1

         suzuki_lhs_nuclide_id = chem_get_iso_id(lhs)
         suzuki_lhs_nuclide_name(rxn_idx) = lhs
         suzuki_rhs_nuclide_id = chem_get_iso_id(rhs)
         suzuki_rhs_nuclide_name(rxn_idx) = rhs
         call create_weak_dict_key(lhs, rhs, key)
         call integer_dict_define(suzuki_reactions_dict, key, rxn_idx, ierr)
         if (failed('integer_dict_define')) return

         ! get dataset size
         data_dims = 0
         call h5dopen_f(group_id, "logTs", dset_id, ierr)
         call h5dget_space_f(dset_id, dspace_id, ierr)
         call H5sget_simple_extent_dims_f(dspace_id, data_dims, max_dims, ierr)
         if (dbg) write(*,*) "num logTs", data_dims(1)
         allocate(logTs(data_dims(1)))
         call h5dread_f(dset_id, H5T_IEEE_F64LE, logTs, data_dims, ierr)
         call h5dclose_f(dset_id, ierr)

         data_dims = 0
         call h5dopen_f(group_id, "lYeRhos", dset_id, ierr)
         call h5dget_space_f(dset_id, dspace_id, ierr)
         call H5sget_simple_extent_dims_f(dspace_id, data_dims, max_dims, ierr)
         if (dbg) write(*,*) "num lYeRhos", data_dims(1)
         allocate(lYeRhos(data_dims(1)))
         call h5dread_f(dset_id, H5T_IEEE_F64LE, lYeRhos, data_dims, ierr)
         call h5dclose_f(dset_id, ierr)

         table = suzuki_rate_table(logTs, lYeRhos)
         call set_nan(table % data)

         data_dims(1) = size(logTs)
         data_dims(2) = size(lYeRhos)

         ! we know we may not find some groups, so silence errors
         call h5eset_auto_f(0, ierr)

         ! read capture group
         table % has_capture_data = .false.
         call h5gopen_f(group_id, "capture", subgroup_id, ierr)
         if (ierr == 0) then

            table % has_capture_data = .true.
            if (dbg) write(*,*) "found capture group; reading..."

            call h5dopen_f(subgroup_id, "mu", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_capture_mu), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            call h5dopen_f(subgroup_id, "dQ", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_capture_dQ), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            call h5dopen_f(subgroup_id, "Vs", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_capture_Vs), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            call h5dopen_f(subgroup_id, "rate", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_capture_rate), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            call h5dopen_f(subgroup_id, "nu", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_capture_nu), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            call h5dopen_f(subgroup_id, "gamma", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_capture_gamma), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            if (ierr /= 0) then
               write(*,*) 'failed to read capture data'
               call mesa_error(__FILE__, __LINE__)
            end if

         end if
         call h5gclose_f(subgroup_id, ierr)


         ! read decay group
         table % has_decay_data = .false.
         call h5gopen_f(group_id, "decay", subgroup_id, ierr)
         if (ierr == 0) then

            table % has_decay_data = .true.
            if (dbg) write(*,*) "found decay group; reading..."

            call h5dopen_f(subgroup_id, "mu", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_decay_mu), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            call h5dopen_f(subgroup_id, "dQ", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_decay_dQ), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            call h5dopen_f(subgroup_id, "Vs", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_decay_Vs), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            call h5dopen_f(subgroup_id, "rate", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_decay_rate), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            call h5dopen_f(subgroup_id, "nu", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_decay_nu), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            call h5dopen_f(subgroup_id, "gamma", dset_id, ierr)
            call h5dread_f(dset_id,  H5T_IEEE_F64LE, table% data(1,:,:,table%i_decay_gamma), data_dims, ierr)
            call h5dclose_f(dset_id, ierr)

            if (ierr /= 0) then
               write(*,*) 'failed to read decay data'
               call mesa_error(__FILE__, __LINE__)
            end if

         end if
         call h5gclose_f(subgroup_id, ierr)

         ! un-silence errors
         call h5eset_auto_f(1, ierr)

         ! assign table
         allocate(suzuki_reactions_tables(rxn_idx)% t, source=table)

      else if(infobuf%type.eq.h5o_type_dataset_f)then
         write(*,*) 'no datasets in root'
         call mesa_error(__FILE__, __LINE__)
      else if(infobuf%type.eq.h5o_type_named_datatype_f)then
         write(*,*) 'no datatypes in root'
         call mesa_error(__FILE__, __LINE__)
      else
         write(*,*) 'no unknowns in root'
         call mesa_error(__FILE__, __LINE__)
      endif

      op_func = 0 ! return successful

    end function op_func

    subroutine alloc

      allocate( &
           suzuki_reaclib_id(num_suzuki_reactions), &
           suzuki_lhs_nuclide_name(num_suzuki_reactions), &
           suzuki_rhs_nuclide_name(num_suzuki_reactions), &
           suzuki_lhs_nuclide_id(num_suzuki_reactions), &
           suzuki_rhs_nuclide_id(num_suzuki_reactions), &
           suzuki_reactions_tables(num_suzuki_reactions), &
           stat=ierr)

    end subroutine alloc

    logical function failed(str)
      character (len=*) :: str
      failed = (ierr /= 0)
      if (failed) then
         write(*,*) 'failed: ' // trim(str)
      end if
    end function failed


  end subroutine private_load_suzuki_tables
#endif

end module suzuki_tables