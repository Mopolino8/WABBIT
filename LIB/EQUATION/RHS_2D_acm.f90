!> \file
!> \callgraph
! ********************************************************************************************
! WABBIT
! ============================================================================================
!> \name RHS_2D_acm.f90
!> \version 0.5
!> \author engels, sm
!
!> \brief RHS for 2D acm penalty method
!
!>
!! input:    - datafield, grid parameter, derivative order \n
!! output:   - RHS(datafield) \n
!!
!!
!! = log ======================================================================================
!! \n
!! 27/06/17 - create
! ********************************************************************************************

subroutine RHS_2D_acm(params, g, Bs, dx, x0, N_dF, phi, order_discretization)

!---------------------------------------------------------------------------------------------
! modules

    ! global parameters
    use module_params

!---------------------------------------------------------------------------------------------
! variables

    implicit none

    !> physics parameter structure
    type (type_params), intent(in)                 :: params

    !> grid parameter
    integer(kind=ik), intent(in)                   :: g, Bs
    !> origin and spacing of the block
    real(kind=rk), dimension(3), intent(in)        :: x0, dx

    !> number of datafields
    integer(kind=ik), intent(in)                   :: N_dF
    !> datafields
    real(kind=rk), intent(inout)                   :: phi(Bs+2*g, Bs+2*g, N_dF)
    !> discretization order
    character(len=80), intent(in)                  :: order_discretization

    real(kind=rk), dimension(Bs+2*g, Bs+2*g, N_dF) :: rhs
    
    !> mask term for every grid point in this block
    real(kind=rk), dimension(Bs+2*g, Bs+2*g)       :: mask
    !> velocity of the solid (set to zero)
    real(kind=rk), dimension(Bs+2*g, Bs+2*g, 2)    :: us


    !> local datafields
    real(kind=rk), dimension(Bs+2*g, Bs+2*g)       :: u, v, p
    !> 
    real(kind=rk)                                  :: dx_inv, dy_inv, dx2_inv, dy2_inv, c_0, nu, eps, eps_inv, gamma
    real(kind=rk)                                  :: div_U, u_dx, u_dy, u_dxdx, u_dydy, v_dx, v_dy, v_dxdx, v_dydy, p_dx, p_dy, penalx, penaly
    ! loop variables
    integer(kind=rk)                               :: ix, iy

!---------------------------------------------------------------------------------------------
! interfaces

!---------------------------------------------------------------------------------------------
! variables initialization

    ! set parameters for readability
    c_0         = params%physics_acm%c_0
    nu          = params%physics_acm%nu
    eps         = params%eps_penal
    gamma       = params%physics_acm%gamma_p

    
    u = phi(:,:,1)
    v = phi(:,:,2)
    p = phi(:,:,3)

    rhs  = 0.0_rk
    mask = 0.0_rk
    us   = 0.0_rk

    dx_inv = 1.0_rk / (2.0_rk*dx(1))
    dy_inv = 1.0_rk / (2.0_rk*dx(2))
    dx2_inv = 1.0_rk / (dx(1)**2)
    dy2_inv = 1.0_rk / (dx(2)**2)

    eps_inv = 1.0_rk / eps
!---------------------------------------------------------------------------------------------
! main body

    if (params%penalization) then
        ! create mask term for every grid point in this block
        call create_mask(params, mask, x0, dx, Bs, g)
        mask = mask*eps_inv
    end if

   if (order_discretization == "FD_2nd_central" ) then
        !-----------------------------------------------------------------------
        ! 2nd order
        !-----------------------------------------------------------------------
        do ix = g+1, Bs+g
            do iy = g+1, Bs+g

                u_dx = (u(ix+1,iy)-u(ix-1,iy))*dx_inv
                u_dy = (u(ix,iy+1)-u(ix,iy-1))*dy_inv
                u_dxdx = (u(ix-1,iy)-2.0_rk*u(ix,iy)+u(ix+1,iy))*dx2_inv
                u_dydy = (u(ix,iy-1)-2.0_rk*u(ix,iy)+u(ix,iy+1))*dy2_inv


                v_dx = (v(ix+1,iy)-v(ix-1,iy))*dx_inv
                v_dy = (v(ix,iy+1)-v(ix,iy-1))*dy_inv
                v_dxdx = (v(ix-1,iy)-2.0_rk*v(ix,iy)+v(ix+1,iy))*dx2_inv
                v_dydy = (v(ix,iy-1)-2.0_rk*v(ix,iy)+v(ix,iy+1))*dy2_inv

                p_dx = (p(ix+1,iy)-p(ix-1,iy))*dx_inv
                p_dy = (p(ix,iy+1)-p(ix,iy-1))*dy_inv

                div_U = u_dx + v_dy

                penalx = -mask(ix,iy)*(u(ix,iy)-us(ix,iy,1))
                penaly = -mask(ix,iy)*(v(ix,iy)-us(ix,iy,2))

                rhs(ix,iy,1) = -u(ix,iy)*u_dx - v(ix,iy)*u_dy - p_dx + nu*(u_dxdx + u_dydy) + penalx + 0.1_rk
                rhs(ix,iy,2) = -u(ix,iy)*v_dx - v(ix,iy)*v_dy - p_dy + nu*(v_dxdx + v_dydy) + penaly + 0.1_rk
                rhs(ix,iy,3) = -(c_0**2)*(div_U) - gamma*p(ix,iy)

                if (N_dF ==4) rhs(ix,iy,4) = v_dx-u_dy
                
              end do
        end do

    end if
    phi = rhs

    ! ! grad(u)
    ! call grad_central(u_dx, u_dy, Bs, g, u, dx_inv, dy_inv)
    ! ! grad(v)
    ! call grad_central(v_dx, v_dy, Bs, g, v, dx_inv, dy_inv)
    ! ! grad(p)
    ! call grad_central(p_dx, p_dy, Bs, g, p, dx_inv, dy_inv)

    ! ! laplace(u)
    ! call laplace_central(u_lapl, Bs, g, u, dx2_inv, dy2_inv)
    ! ! laplace(v)
    ! call laplace_central(v_lapl, Bs, g, v, dx2_inv, dy2_inv)

    ! ! penalization term
    ! penalx = -mask*(u-us(:,:,1))
    ! penaly = -mask*(v-us(:,:,2))
    ! ! divergence of u
    ! div_U  = u_dx + v_dy

    ! !RHS
    ! rhs(:,:,1) = -u*div_U - p_dx + nu*u_lapl + penalx
    ! rhs(:,:,2) = -v*div_U - p_dy + nu*v_lapl + penaly
    ! rhs(:,:,3) = -(c_0**2)*(div_U)

end subroutine RHS_2D_acm


! subroutine grad_central(u_dx, u_dy, Bs, g, u, dx_inv, dy_inv)
! !---------------------------------------------------------------------------------------------
! ! modules
!     ! global parameters
!     use module_params
! !---------------------------------------------------------------------------------------------
! ! variables
!     implicit none
!     integer(kind=ik), intent(in)                         :: Bs, g
!     real(kind=rk), dimension(2*g+Bs,2*g+Bs), intent(in)  :: u
!     real(kind=rk), dimension(2*g+Bs,2*g+Bs), intent(out) :: u_dx, u_dy
!     real(kind=rk), intent(in)                            :: dx_inv, dy_inv
!     integer(kind=ik)                                     :: ix, iy
! !---------------------------------------------------------------------------------------------
! ! main body
!    u_dx = 0.0_rk
!    u_dy = 0.0_rk
!    do ix = g+1, Bs+g
!        do iy = g+1, Bs+g
!            u_dx(ix,iy) = (u(ix+1,iy)-u(ix-1,iy))*dx_inv
!            u_dy(ix,iy) = (u(ix,iy+1)-u(ix,iy-1))*dy_inv
!        end do
!   end do

! end subroutine grad_central


! subroutine laplace_central(u_dxdx, Bs, g, u, dx2_inv, dy2_inv)
! !---------------------------------------------------------------------------------------------
! ! modules
!     ! global parameters
!     use module_params
! !---------------------------------------------------------------------------------------------
! ! variables
!     implicit none
!     integer(kind=ik), intent(in)                         :: Bs, g
!     real(kind=rk), dimension(2*g+Bs,2*g+Bs), intent(in)  :: u
!     real(kind=rk), dimension(2*g+Bs,2*g+Bs), intent(out) :: u_lapl
!     real(kind=rk), intent(in)                            :: dx2_inv, dy2_inv
!     real(kind=rk)                                        :: u_dxdx, u_dydy
!     integer(kind=ik)                                     :: ix, iy
! !---------------------------------------------------------------------------------------------
! ! main body
!    u_lapl = 0.0_rk 
!    do ix = g+1, Bs+g
!        do iy = g+1, Bs+g
!            u_dxdx        = (u(ix-1,iy)-2.0_rk*u(ix,iy)+u(ix+1,iy))*dx2_inv
!            u_dydy        = (u(ix,iy-1)-2.0_rk*u(ix,iy)+u(ix,iy+1))*dy2_inv
!            u_lapl(ix,iy) = u_dxdx + u_dydy
!        end do
!   end do

! end subroutine laplace_central
