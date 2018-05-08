!> \file
!> \callgraph
! ********************************************************************************************
! WABBIT
! ============================================================================================
!> \name set_RK_input.f90
!> \version 0.5
!> \author sm
!
!> \brief set input for Runge Kutta time stepper
!
!>
!! gives back the input for the RHS (from which in the final stage the next time step is computed).\n 
!!
!! k_j = RHS(t+dt*c_j, datafield(t) + dt*sum(a_jl*k_l)) (e.g. k3 = RHS(t+dt*c_3, data_field(t) + dt*(a31*k1+a32*k2)) ) \n
!!
!! This routine is in charge of setting the input and saving it in the hvy_work and hvy_block array \n
!!
!! input:    
!!           - time step dt
!!           - params
!!           - heavy data
!!           - coefficients for Runge Kutta method
!!           - loop variable
!!
!! output:   
!!           - heavy_work array
!!
!!
!! butcher table, e.g.
!!
!! |   |    |    |   |
!! |---|----|----|---|
!! | 0 | 0  | 0  |  0|
!! |c2 | a21| 0  |  0|
!! |c3 | a31| a32|  0|
!! | 0 | b1 | b2 | b3|
!!
!!
!! = log ======================================================================================
!! \n
!! 22/05/17 - create
!
! ********************************************************************************************

subroutine set_RK_input(dt, params, rk_coeffs, j, hvy_block, hvy_work, hvy_active, hvy_n)

!---------------------------------------------------------------------------------------------
! modules

!---------------------------------------------------------------------------------------------
! variables

    implicit none
    
    !> dt
    real(kind=rk), intent(in)           :: dt

    !> array containing Runge-Kutta coefficients
    real(kind=rk), intent(in)           :: rk_coeffs(:)
    !> loop variable
    integer(kind=ik), intent(in)        :: j
    !> user defined parameter structure
    type (type_params), intent(in)      :: params
    !> heavy data array - block data
    real(kind=rk), intent(inout)        :: hvy_block(:, :, :, :, :)
    !> heavy work data array - block data
    real(kind=rk), intent(in)           :: hvy_work(:, :, :, :, :)

    !> list of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_active(:)
    !> number of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_n

    ! loop variables
    integer(kind=ik)                    :: l, dF, N_dF, k


!---------------------------------------------------------------------------------------------
! variables initialization

    N_dF  = params%number_data_fields

!---------------------------------------------------------------------------------------------
! main body


    select case(params%physics_type)

        case('2D_convection_diffusion')
            ! first: k_j = RHS(data_field(t) + ...
            do dF = 1, N_dF
                do k = 1, hvy_n
                    hvy_block( :, :, :, dF, hvy_active(k)) = hvy_work( :, :, :, (dF-1)*5+1, hvy_active(k) )
                end do
            end do
            do l = 2, j
                ! check if coefficient is zero - if so, avoid loop over all data fields and active blocks
                if (abs(rk_coeffs(l)) < 1e-8_rk) then
                else
                    ! loop over all data fields
                    do dF = 1, N_dF
                        ! loop over all active heavy data blocks 
                        do k = 1, hvy_n
                            ! new input for computation of k-coefficients
                            ! k_j = RHS(data_field(t) + sum(a_jl*k_l))
                            hvy_block( :, :, :, dF, hvy_active(k)) = hvy_block( :, :, :, dF, hvy_active(k)) &
                                         + dt * rk_coeffs(l) * hvy_work( :, :, :, (dF-1)*5+l, hvy_active(k))
                        end do
                    end do
                end if
            end do

        case('2D_navier_stokes')
            ! first: k_j = RHS(data_field(t) + ...
            ! loop over all active heavy data blocks
            do k = 1, hvy_n
                hvy_block( :, :, :, 1:N_dF, hvy_active(k)) = hvy_work( :, :, :, 1:N_dF, hvy_active(k) )
            end do
            do l = 2, j
                ! check if coefficient is zero - if so, avoid loop over all data fields and active blocks
                if (abs(rk_coeffs(l)) < 1e-8_rk) then
                else
                    ! loop over all active heavy data blocks 
                    do k = 1, hvy_n
                        ! new input for computation of k-coefficients
                        ! k_j = RHS(data_field(t) + sum(a_jl*k_l))
                        hvy_block( :, :, :, 1:N_dF, hvy_active(k)) = hvy_block( :, :, :, 1:N_dF, hvy_active(k)) &
                                    + dt * rk_coeffs(l) * hvy_work( :, :, :, (l-1)*N_dF+1:l*N_dF, hvy_active(k))
                    end do
                end if
            end do

        case('3D_convection_diffusion')
            ! first: k_j = RHS(data_field(t) + ...
            do dF = 1, N_dF
                do k = 1, hvy_n
                    hvy_block( :, :, :, dF, hvy_active(k)) = hvy_work( :, :, :, (dF-1)*5+1, hvy_active(k) )
                end do
            end do
            do l = 2, j
                ! check if coefficient is zero - if so, avoid loop over all data fields and active blocks
                if (abs(rk_coeffs(l)) < 1e-8_rk) then
                else
                    ! loop over all data fields
                    do dF = 1, N_dF
                        ! loop over all active heavy data blocks 
                        do k = 1, hvy_n
                            ! new input for computation of k-coefficients
                            ! k_j = RHS(data_field(t) + sum(a_jl*k_l))
                            hvy_block( :, :, :, dF, hvy_active(k)) = hvy_block( :, :, :, dF, hvy_active(k))&
                                         + dt * rk_coeffs(l) * hvy_work( :, :, :, (dF-1)*5+l, hvy_active(k))
                        end do
                    end do
                end if
            end do

        case('3D_navier_stokes')
            ! first: k_j = RHS(data_field(t) + ..
            ! loop over all active heavy data blocks
            do k = 1, hvy_n
                hvy_block( :, :, :, 1:N_dF, hvy_active(k)) = hvy_work( :, :, :, 1:N_dF, hvy_active(k) )
            end do
            do l = 2, j
                ! check if coefficient is zero - if so, avoid loop over all data fields and active blocks
                if (abs(rk_coeffs(l)) < 1e-8_rk) then
                else
                    ! loop over all active heavy data blocks 
                    do k = 1, hvy_n
                        ! new input for computation of k-coefficients
                        ! k_j = RHS(data_field(t) + sum(a_jl*k_l))
                        hvy_block( :, :, :, 1:N_dF, hvy_active(k)) = hvy_block( :, :, :, 1:N_dF, hvy_active(k)) &
                                      + dt * rk_coeffs(l) * hvy_work( :, :, :, (l-1)*N_dF+1:l*N_dF, hvy_active(k))
                    end do
                end if
            end do

        case('2D_advection')
            ! first: k_j = RHS(data_field(t) + ..
            do dF = 1, N_dF
                do k = 1, hvy_n
                    hvy_block( :, :, :, dF, hvy_active(k)) = hvy_work( :, :, :, (dF-1)*5+1, hvy_active(k) )
                end do
            end do
            do l = 2, j
                ! check if coefficient is zero - if so, avoid loop over all data fields and active blocks
                if (abs(rk_coeffs(l)) < 1e-8_rk) then
                else
                    ! loop over all data fields
                    do dF = 1, N_dF
                        ! loop over all active heavy data blocks 
                        do k = 1, hvy_n
                            ! new input for computation of k-coefficients
                            ! k_j = RHS((t+dt*c_j, data_field(t) + sum(a_jl*k_l)) 
                            !(time-dependent rhs, input for time is set in RHS_wrapper)
                            hvy_block( :, :, :, dF, hvy_active(k)) = hvy_block( :, :, :, dF, hvy_active(k)) &
                                        + dt * rk_coeffs(l) * hvy_work( :, :, :, (dF-1)*5+l, hvy_active(k))
                        end do
                    end do
                end if
            end do

        case('3D_advection')
            ! first: k_j = RHS(data_field(t) + ..
            do dF = 1, N_dF
                do k = 1, hvy_n
                    hvy_block( :, :, :, dF, hvy_active(k)) = hvy_work( :, :, :, (dF-1)*5+1, hvy_active(k) )
                end do
            end do
            do l = 2, j
                ! check if coefficient is zero - if so, avoid loop over all data fields and active blocks
                if (abs(rk_coeffs(l)) < 1e-8_rk) then
                else
                    ! loop over all data fields
                    do dF = 1, N_dF
                        ! loop over all active heavy data blocks
                        do k = 1, hvy_n
                            ! new input for computation of k-coefficients
                            ! k_j = RHS((t+dt*c_j, data_field(t) + sum(a_jl*k_l))
                            !(time-dependent rhs, input for time is set in RHS_wrapper)
                            hvy_block( :, :, :, dF, hvy_active(k)) = hvy_block( :, :, :, dF, hvy_active(k)) &
                                        + dt * rk_coeffs(l) * hvy_work( :, :, :, (dF-1)*5+l, hvy_active(k))
                        end do
                    end do
                end if
            end do

        case('2D_acm')
            ! first: k_j = RHS(data_field(t) + ...
            ! loop over all active heavy data blocks
            do k = 1, hvy_n
                hvy_block( :, :, :, 1:N_dF, hvy_active(k)) = hvy_work( :, :, :, 1:N_dF, hvy_active(k) )
            end do
            do l = 2, j
                ! check if coefficient is zero - if so, avoid loop over all data fields and active blocks
                if (abs(rk_coeffs(l)) < 1e-8_rk) then
                else
                    ! loop over all active heavy data blocks 
                    do k = 1, hvy_n
                        ! new input for computation of k-coefficients
                        ! k_j = RHS((t+dt*c_j, data_field(t) + sum(a_jl*k_l))
                        hvy_block( :, :, :, 1:N_dF, hvy_active(k)) = hvy_block( :, :, :, 1:N_dF, hvy_active(k)) &
                                    + dt * rk_coeffs(l) * hvy_work( :, :, :, (l-1)*N_dF+1:l*N_dF, hvy_active(k))
                    end do
                end if
            end do

        case('3D_acm')
            ! first: k_j = RHS(data_field(t) + ...
            ! loop over all active heavy data blocks
            do k = 1, hvy_n
                hvy_block( :, :, :, 1:N_dF, hvy_active(k)) = hvy_work( :, :, :, 1:N_dF, hvy_active(k) )
            end do
            do l = 2, j
                ! check if coefficient is zero - if so, avoid loop over all data fields and active blocks
                if (abs(rk_coeffs(l)) < 1e-8_rk) then
                else
                    ! loop over all active heavy data blocks 
                    do k = 1, hvy_n
                        ! new input for computation of k-coefficients
                        ! k_j = RHS((t+dt*c_j, data_field(t) + sum(a_jl*k_l))
                        hvy_block( :, :, :, 1:N_dF, hvy_active(k)) = hvy_block( :, :, :, 1:N_dF, hvy_active(k)) &
                                    + dt * rk_coeffs(l) * hvy_work( :, :, :, (l-1)*N_dF+1:l*N_dF, hvy_active(k))
                    end do
                end if
            end do

        case default
                write(*,'(80("_"))')
                write(*,*) "ERROR: physics type is unknown"
                write(*,*) params%physics_type
                stop
    end select


end subroutine set_RK_input
