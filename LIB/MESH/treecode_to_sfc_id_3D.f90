!> \file
!> \callgraph
! ********************************************************************************************
! WABBIT
! ============================================================================================
!> \name treecode_to_sfc_id_3D.f90
!> \version 0.5
!> \author msr
!
!> \brief convert given treecode to position in sfc
!
!> 
!! input:    - treecode \n
!! output:   - position in sfc curve \n
!!
!!
!! = log ======================================================================================
!! \n
!! 09/02/17 - create
!
! ********************************************************************************************

subroutine treecode_to_sfc_id_3D(sfc_id, treecode, n)

!---------------------------------------------------------------------------------------------
! modules

!---------------------------------------------------------------------------------------------
! variables

    implicit none

    !> sfc id
    integer(kind=ik), intent(out)       :: sfc_id

    !> treecode size
    integer(kind=ik), intent(in)        :: n

    !> treecode
    integer(kind=ik), intent(in)        :: treecode(n)

    !> loop variable
    integer(kind=ik)                    :: k

!---------------------------------------------------------------------------------------------
! variables initialization

    sfc_id = 0

!---------------------------------------------------------------------------------------------
! main body

    ! calculate sfc id
    ! change -1 in treecode to 0
    ! so every treecode is on highest level
    do k = 1, n
        if ( treecode(n-k+1) == -1 ) then
            ! nothing to do, treecode element is "0"
        else
            ! non zero element
            sfc_id = sfc_id + 8**(k-1) * treecode(n-k+1)
        end if
    end do

end subroutine treecode_to_sfc_id_3D
