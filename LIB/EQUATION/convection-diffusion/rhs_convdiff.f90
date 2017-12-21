!> \file
!> \callgraph
! ********************************************************************************************
! WABBIT
! ============================================================================================
!> \name RHS_2D_acm.f90
!> \version 0.5
!> \author engels, sm
!
!> \brief RHS for 2D artificial compressibility method
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

subroutine RHS_2D_convdiff_new(time, g, Bs, dx, x0, phi, rhs)

!---------------------------------------------------------------------------------------------
! modules

    ! global parameters
    ! use module_params
    ! use module_operators

    implicit none

    !> time
    real(kind=rk), intent(in)                      :: time
    !> grid parameter
    integer(kind=ik), intent(in)                   :: g, Bs
    !> origin and spacing of the block
    real(kind=rk), intent(in)                      :: x0(:), dx(:)
    !> datafields
    real(kind=rk), intent(in)                      :: phi(:,:,:,:)
    real(kind=rk), intent(inout)                     :: rhs(:,:,:,:)

    real(kind=rk) :: u0(1:Bs+2*g, 1:Bs+2*g, 1:2)
    real(kind=rk) :: dx_inv, dy_inv, dx2_inv, dy2_inv,nu
    real(kind=rk) :: u_dx, u_dy, u_dxdx, u_dydy
    real(kind=rk) :: u_dz, u_dzdz
    ! loop variables
    integer(kind=ik)                               :: ix, iy,iz, i, N
    ! coefficients for Tam&Webb
    real(kind=rk)                                  :: a(-3:3)
    real(kind=rk)                                  :: b(-2:2)

    ! set parameters for readability
    N = params_convdiff%N_scalars
    u0 = 0.0_rk
    rhs = 0.0_rk

    dx_inv = 1.0_rk / dx(1)
    dy_inv = 1.0_rk / dx(2)
    dx2_inv = 1.0_rk / (dx(1)**2)
    dy2_inv = 1.0_rk / (dx(2)**2)

    ! Tam & Webb, 4th order optimized (for first derivative)
    a = (/-0.02651995_rk, +0.18941314_rk, -0.79926643_rk, 0.0_rk, 0.79926643_rk, -0.18941314_rk, 0.02651995_rk/)
    ! 4th order coefficients for second derivative
    b = (/ -1.0_rk/12.0_rk, 4.0_rk/3.0_rk, -5.0_rk/2.0_rk, 4.0_rk/3.0_rk, -1.0_rk/12.0_rk /)


    ! looop over components - they are independent scalars
    do i = 1, N
      if (maxval(phi(:,:,:,i))>2.0) call abort(666,"large")

      ! create the advection velocity field, which may be time and space dependent
      call create_velocity_field_2d( time, g, Bs, dx, x0, u0, i )

      ! because p%nu might load the entire params in the cache and thus be slower:
      nu = params_convdiff%nu(i)

      if (params_convdiff%dim == 2) then
        select case(params_convdiff%discretization)
          !-----------------------------------------------------------------------
          ! 2nd order
          !-----------------------------------------------------------------------
        case("FD_2nd_central")
          if (nu>=1.0e-10) then ! with viscosity
            do ix = g+1, Bs+g
              do iy = g+1, Bs+g
                u_dx = (phi(ix+1,iy,1,i)-phi(ix-1,iy,1,i))*dx_inv*0.5_rk
                u_dy = (phi(ix,iy+1,1,i)-phi(ix,iy-1,1,i))*dy_inv*0.5_rk

                u_dxdx = (phi(ix-1,iy,1,i)-2.0_rk*phi(ix,iy,1,i)+phi(ix+1,iy,1,i))*dx2_inv
                u_dydy = (phi(ix,iy-1,1,i)-2.0_rk*phi(ix,iy,1,i)+phi(ix,iy+1,1,i))*dy2_inv

                rhs(ix,iy,1,i) = -u0(ix,iy,1)*u_dx -u0(ix,iy,2)*u_dy + nu*(u_dxdx+u_dydy)
              end do
            end do
          else !  no viscosity
            do ix = g+1, Bs+g
              do iy = g+1, Bs+g
                u_dx = (phi(ix+1,iy,1,i)-phi(ix-1,iy,1,i))*dx_inv*0.5_rk
                u_dy = (phi(ix,iy+1,1,i)-phi(ix,iy-1,1,i))*dy_inv*0.5_rk

                rhs(ix,iy,1,i) = -u0(ix,iy,1)*u_dx -u0(ix,iy,2)*u_dy
              end do
            end do

          endif
          !-----------------------------------------------------------------------
          ! 4th order
          !-----------------------------------------------------------------------
        case("FD_4th_central_optimized")
          if (nu>=1.0e-10) then ! with viscosity
            do ix = g+1, Bs+g
              do iy = g+1, Bs+g
                ! gradient
                u_dx = (a(-3)*phi(ix-3,iy,1,i) + a(-2)*phi(ix-2,iy,1,i) + a(-1)*phi(ix-1,iy,1,i) + a(0)*phi(ix,iy,1,i)&
                +  a(+3)*phi(ix+3,iy,1,i) + a(+2)*phi(ix+2,iy,1,i) + a(+1)*phi(ix+1,iy,1,i))*dx_inv
                u_dy = (a(-3)*phi(ix,iy-3,1,i) + a(-2)*phi(ix,iy-2,1,i) + a(-1)*phi(ix,iy-1,1,i) + a(0)*phi(ix,iy,1,i)&
                +  a(+3)*phi(ix,iy+3,1,i) + a(+2)*phi(ix,iy+2,1,i) + a(+1)*phi(ix,iy+1,1,i))*dy_inv

                u_dxdx = (b(-2)*phi(ix-2,iy,1,1) + b(-1)*phi(ix-1,iy,1,1) + b(0)*phi(ix,iy,1,1)+ b(+1)*phi(ix+1,iy,1,1) + b(+2)*phi(ix+2,iy,1,1))*dx2_inv
                u_dydy = (b(-2)*phi(ix,iy-2,1,1) + b(-1)*phi(ix,iy-1,1,1) + b(0)*phi(ix,iy,1,1)+ b(+1)*phi(ix,iy+1,1,1) + b(+2)*phi(ix,iy+2,1,1))*dy2_inv

                rhs(ix,iy,1,i) = -u0(ix,iy,1)*u_dx -u0(ix,iy,2)*u_dy + nu*(u_dxdx+u_dydy)
              end do
            end do
          else ! no viscosity
            do ix = g+1, Bs+g
              do iy = g+1, Bs+g
                ! gradient
                u_dx = (a(-3)*phi(ix-3,iy,1,i) + a(-2)*phi(ix-2,iy,1,i) + a(-1)*phi(ix-1,iy,1,i) + a(0)*phi(ix,iy,1,i)&
                +  a(+3)*phi(ix+3,iy,1,i) + a(+2)*phi(ix+2,iy,1,i) + a(+1)*phi(ix+1,iy,1,i))*dx_inv
                u_dy = (a(-3)*phi(ix,iy-3,1,i) + a(-2)*phi(ix,iy-2,1,i) + a(-1)*phi(ix,iy-1,1,i) + a(0)*phi(ix,iy,1,i)&
                +  a(+3)*phi(ix,iy+3,1,i) + a(+2)*phi(ix,iy+2,1,i) + a(+1)*phi(ix,iy+1,1,i))*dy_inv

                rhs(ix,iy,1,i) = -u0(ix,iy,1)*u_dx -u0(ix,iy,2)*u_dy
              end do
            end do
          endif

        case default
          call abort(442161, params_convdiff%discretization//" discretization unkown, goto hell.")
        end select

      else
        select case(params_convdiff%discretization)
        ! !-----------------------------------------------------------------------
        ! ! 2nd order
        ! !-----------------------------------------------------------------------
        ! case("FD_2nd_central")
        !   do ix = g+1, Bs+g
        !     do iy = g+1, Bs+g
        !       do iz = g+1, Bs+g
        !         u_dx = (phi(ix+1,iy,iz,i)-phi(ix-1,iy,iz,i))*dx_inv*0.5_rk
        !         u_dy = (phi(ix,iy+1,iz,i)-phi(ix,iy-1,iz,i))*dy_inv*0.5_rk
        !         u_dz = (phi(ix,iy,iz+1,i)-phi(ix,iy,iz-1,i))*dy_inv*0.5_rk
        !
        !         u_dxdx = (phi(ix-1,iy,iz,i)-2.0_rk*phi(ix,iy,iz,i)+phi(ix+1,iy,iz,i))*dx2_inv
        !         u_dydy = (phi(ix,iy-1,iz,i)-2.0_rk*phi(ix,iy,iz,i)+phi(ix,iy+1,iz,i))*dy2_inv
        !         u_dzdz = (phi(ix,iy,iz-1,i)-2.0_rk*phi(ix,iy,iz,i)+phi(ix,iy,iz+1,i))*dy2_inv
        !
        !         rhs(ix,iy,iz,i) = -u0(ix,iy,iz,1)*u_dx -u0(ix,iy,iz,2)*u_dy -u0(ix,iy,iz,3)*u_dz &
        !         + nu*(u_dxdx+u_dydy+u_dzdz)
        !       end do
        !     end do
        !   end do

        !-----------------------------------------------------------------------
        ! 4th order
        !-----------------------------------------------------------------------
        ! case("FD_4th_central_optimized")
        !   do ix = g+1, Bs+g
        !     do iy = g+1, Bs+g
        !       ! gradient
        !       u_dx = (a(-3)*phi(ix-3,iy,i) + a(-2)*phi(ix-2,iy,i) + a(-1)*phi(ix-1,iy,i) + a(0)*phi(ix,iy,i)&
        !       +  a(+3)*phi(ix+3,iy,i) + a(+2)*phi(ix+2,iy,i) + a(+1)*phi(ix+1,iy,i))*dx_inv
        !       u_dy = (a(-3)*phi(ix,iy-3,i) + a(-2)*phi(ix,iy-2,i) + a(-1)*phi(ix,iy-1,i) + a(0)*phi(ix,iy,i)&
        !       +  a(+3)*phi(ix,iy+3,i) + a(+2)*phi(ix,iy+2,i) + a(+1)*phi(ix,iy+1,i))*dy_inv
        !
        !       u_dxdx = (b(-2)*phi(ix-2,iy,1) + b(-1)*phi(ix-1,iy,1) + b(0)*phi(ix,iy,1)+ b(+1)*phi(ix+1,iy,1) + b(+2)*phi(ix+2,iy,1))*dx2_inv
        !       u_dydy = (b(-2)*phi(ix,iy-2,1) + b(-1)*phi(ix,iy-1,1) + b(0)*phi(ix,iy,1)+ b(+1)*phi(ix,iy+1,1) + b(+2)*phi(ix,iy+2,1))*dy2_inv
        !
        !       rhs(ix,iy,i) = -u0(ix,iy,1)*u_dx -u0(ix,iy,2)*u_dy + nu*(u_dxdx+u_dydy)
        !     end do
        !   end do

        case default
          call abort(442161, params_convdiff%discretization//" discretization unkown, goto hell.")
        end select
      endif
    end do

end subroutine RHS_2D_convdiff_new



subroutine create_velocity_field_2D( time, g, Bs, dx, x0, u0, i )
  implicit none
  real(kind=rk), intent(in) :: time
  integer(kind=ik), intent(in) :: g, Bs, i
  real(kind=rk), intent(in) :: dx(1:2), x0(1:2)
  real(kind=rk), intent(inout) :: u0(:,:,:)

  integer :: ix,iy, N
  real(kind=rk) :: x,y,c0x,c0y, T

  u0 = 0.0_rk

  if (params_convdiff%dim == 2) then
    c0x = 0.5_rk*params_convdiff%Lx
    c0y = 0.5_rk*params_convdiff%Ly
    T = params_convdiff%T_end


    select case(params_convdiff%velocity(i))
    case ("swirl")

      do iy = 1, Bs + 2*g
        do ix = 1, Bs + 2*g
          x = dble(ix-(g+1)) * dx(1) + x0(1)
          y = dble(iy-(g+1)) * dx(2) + x0(2)

          u0(ix,iy,1) = cos((pi*time)/T) * (sin(pi*x))**2 * sin(2*pi*y)
          u0(ix,iy,2) = cos((pi*time)/T) * (sin(pi*y))**2 * (-sin(2*pi*x))
        enddo
      enddo


    case("constant")
      u0(:,:,1) = params_convdiff%u0x(i)
      u0(:,:,2) = params_convdiff%u0y(i)

    case default
      call abort(77262,params_convdiff%velocity(i)//' is an unkown velocity field')

    end select
  endif
end subroutine



subroutine create_velocity_field_3D( time, g, Bs, dx, x0, u0, i )
  implicit none
  real(kind=rk), intent(in) :: time
  integer(kind=ik), intent(in) :: g, Bs, i
  real(kind=rk), intent(in) :: dx(1:3), x0(1:3)
  real(kind=rk), intent(inout) :: u0(:,:,:,1:)

  integer :: ix,iy, N
  real(kind=rk) :: x,y,c0x,c0y, T

  return
end subroutine
