! ***********************************************************************
!
!   Copyright (C) 2010-2016  Bill Paxton, Rich Townsend
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

module utils_nan

  ! Uses

  use utils_nan_sp
  use utils_nan_dp
  use utils_nan_qp

  ! No implicit typing
      
  implicit none

  ! Access specifiers

  private

  public :: is_nan
  public :: is_inf
  public :: is_bad
  public :: set_nan

end module utils_nan