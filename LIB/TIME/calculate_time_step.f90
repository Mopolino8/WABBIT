!> \file
!> \callgraph
! ********************************************************************************************
! WABBIT
! ============================================================================================
!> \name calculate_time_step.f90
!> \version 0.5
!> \author sm
!
!> \brief calculate time step
!
!>
!! input:    -  params \n
!! output:   -  time step dt \n
!!
!!
!! = log ======================================================================================
!! \n
!! 18/04/17 - create
!
! ********************************************************************************************
subroutine calculate_time_step( params, hvy_block, hvy_active, hvy_n, lgt_block, lgt_active, lgt_n, dx, dt )

!---------------------------------------------------------------------------------------------
! variables

    implicit none
    !> user defined parameter structure
    type (type_params), intent(in)      :: params

    !> heavy data array - block data
    real(kind=rk), intent(in)           :: hvy_block(:, :, :, :, :)

    !> list of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_active(:)

    !> number of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_n

    !> light data array
    integer(kind=ik), intent(in)        :: lgt_block(:, :)
    !> list of active blocks (light data)
    integer(kind=ik), intent(in)        :: lgt_active(:)
    !> number of active blocks (light data)
    integer(kind=ik), intent(in)        :: lgt_n

    !> dx
    real(kind=rk)                       :: dx
    !> time step dt
    real(kind=rk), intent(out)          :: dt

    ! loop variables
    integer(kind=ik)                    :: dF, N_dF, UxF, UyF, UzF

    ! norm of vector u
    real(kind=rk)                       :: norm_u, my_norm_u

    ! MPI error variable
    integer(kind=ik)                    :: ierr

    ! maximal mesh level
    integer(kind=ik)                    :: Jmax

    reaL(kind=rk ) :: ddx(1:3), xx0(1:3), dt_tmp
    integer(kind=ik) :: k, lgt_id

!---------------------------------------------------------------------------------------------
! variables initialization

    N_dF  = params%number_data_fields

    UxF  = 0
    UyF  = 0
    UzF  = 0

!---------------------------------------------------------------------------------------------
! main body

!$$$$$$$$$$$$$$ NEW CODE $$$$$$$$$$$$$$$$
  if (params%physics_type == 'ACM-new' .or. params%physics_type == 'ConvDiff-new') then
    dt = 9.0e9_rk
    do k = 1, hvy_n

        call hvy_id_to_lgt_id(lgt_id, hvy_active(k), params%rank, params%number_blocks)
        call get_block_spacing_origin( params, lgt_id, lgt_block, xx0, ddx )

        select case (params%physics_type)
        case ('ACM-new')
          call GET_DT_BLOCK_ACM( 0.0_rk, hvy_block(:,:,:,:,hvy_active(k)), params%number_ghost_nodes, xx0, ddx, dt_tmp )

        case ('ConvDiff-new')
          call GET_DT_BLOCK_convdiff( 0.0_rk, hvy_block(:,:,:,:,hvy_active(k)), params%number_block_nodes, &
           params%number_ghost_nodes, xx0, ddx, dt_tmp )

        case default
          call abort('phycics module unkown.')
        end select

        dt = min( dt, dt_tmp )

    end do

    ! synchronize time steps
    ! store local (per process) time step
    dt_tmp = dt
    ! global minimum time step
    call MPI_Allreduce(dt_tmp, dt, 1, MPI_REAL8, MPI_MIN, MPI_COMM_WORLD, ierr)

    goto 10
  endif

!$$$$$$$$$$$$$$ OLD CODE $$$$$$$$$$$$$$$$
    select case(params%time_step_calc)
        case('fixed')
            dt = params%dt

        case('CFL_cond')

            ! convection_diffusion, advection physics
            if (allocated(params%physics%u0)) then
               ! calculate time step, loop over all data fields
               !> \todo CFL time step calculation do not work with ns physics
               if ( params%threeD_case ) then
                  do dF = 1, N_dF
                     norm_u = norm2( params%physics%u0((dF-1)*2 + 1 : (dF-1)*2 + 3 ))
                     ! check for zero velocity to avoid divison by zero
                     if (norm_u < 1e-12_rk) norm_u = 9e9_rk
                     dt = minval((/dt, params%CFL * dx / norm_u /))
                  end do
               else
                  do dF = 1, N_dF
                     norm_u = norm2( params%physics%u0((dF-1)*2 + 1 : (dF-1)*2 + 2 ))
                     ! check for zero velocity to avoid divison by zero
                     if (norm_u < 1e-12_rk) norm_u = 9e9_rk
                     dt = minval((/dt, params%CFL * dx / norm_u /))
                  end do
               end if

            ! ns physics
            elseif ( params%physics_type == '2D_navier_stokes' ) then
                ! velocity field numbers
                do dF = 1, N_dF
                    if ( params%physics_ns%names(dF) == "Ux" ) UxF = dF
                    if ( params%physics_ns%names(dF) == "Uy" ) UyF = dF
                    if ( params%physics_ns%names(dF) == "Uz" ) UzF = dF
                end do
                ! max velocity over all blocks
                call get_block_max_velocity_norm( params, hvy_block, hvy_active, hvy_n, (/ UxF, UyF, UzF /), my_norm_u )

                ! synchronize
                call MPI_Allreduce(my_norm_u, norm_u, 1, MPI_REAL8, MPI_MAX, MPI_COMM_WORLD, ierr)

                if (norm_u < 1e-12_rk) norm_u = 9e9_rk

                dt = minval((/dt, params%CFL * dx / norm_u /))

            ! fixed value
            else
                dt = params%dt
            end if

        case('lvl_fixed')

            ! find Jmax
            Jmax = max_active_level( lgt_block, lgt_active, lgt_n )

            dt = params%dt / 2**Jmax

        case default
            write(*,'(80("_"))')
            write(*,*) "ERROR: time stepper method ist unknown"
            write(*,*) params%time_step_calc
            stop

    end select
    ! penalization stability criterion
    if (params%penalization) dt = minval( (/dt, 0.99_rk*params%eps_penal /) )

10 continue
end subroutine calculate_time_step
