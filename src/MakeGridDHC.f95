subroutine MakeGridDHC(griddh, n, cilm, lmax, norm, sampling, &
                       csphase, lmax_calc, extend, exitstatus)
!------------------------------------------------------------------------------
!
!   Given the Spherical Harmonic coefficients CILM of a function, this
!   subroutine will evalate the function on a grid with an equal number of
!   samples N in both latitude and longitude (or N by 2N by specifying the
!   optional parameter SAMPLING = 2). This is the inverse of the routine
!   SHExpandDH, both of which are done quickly using FFTs for each degree of
!   each latitude band. The number of samples is determined by the spherical
!   harmonic bandwidth LMAX, but the coefficients can be evaluated up to a
!   smaller spherical harmonic degree by specifying the optional parameter
!   LMAX_CALC. Note that N is always even for this routine.
!
!   The Legendre functions are computed on the fly using the scaling
!   methodology presented in Holmes and Featherston (2002). When NORM = 1, 2
!   or 4, these are accurate to about degree 2800. When NORM = 3, the routine
!   is only stable to about degree 15.
!
!   When SAMPLING = 1, the output grid contains N samples in latitude from
!   90 to -90 + interval and N samples in longitude from 0 to 360-2*interval,
!   where N=2*(LMAX+1) and interval=180/N. When SAMPLING = 2, the grid is
!   equally spaced in degrees latitude and longitude with dimension (N x 2N).
!   If the optional parameter EXTEND is set to 1, the output grid will contain
!   an extra column corresponding to 360 E and an extra row corresponding to
!   90 S, which increases each of the dimensions of the grid by one.
!   by one.
!
!   The complex spherical harmonics are output in the array CILM. CILM(1,,)
!   contains the positive m term, wheras CILM(2,,) contains the negative m
!   term. The negative order Legendre functions are calculated making use of
!   the identity Y_{lm}^* = (-1)^m Y_{l,-m}.
!
!   Calling Parameters
!
!       IN
!           cilm        Input spherical harmonic coefficients with
!                       dimension (2, lmax+1, lmax+1).
!           lmax        Maximum spherical harmonic degree used in the
!                       expansion. This determines the spacing of the output
!                       grid.
!
!       OUT
!           griddh      Gridded data of the spherical harmonic coefficients
!                       CILM with dimensions (n, sampling*n) or
!                       (n+1, sampling*n+1).
!           n           Number of samples in the grid, always even, which is
!                       2*(LMAX+2).
!
!       OPTIONAL (IN)
!           norm        Normalization to be used when calculating Legendre
!                       functions
!                           (1) "geodesy" (default)
!                           (2) Schmidt
!                           (3) unnormalized
!                           (4) orthonormalized
!           sampling    (1) Grid is N latitudes by N longitudes (default).
!                       (2) Grid is N by 2N. The higher frequencies resulting
!                       from this oversampling in longitude are discarded, and
!                       hence not aliased into lower frequencies.
!           csphase     1: Do not include the phase factor of (-1)^m
!                       -1: Apply the phase factor of (-1)^m.
!           lmax_calc   The maximum spherical harmonic degree to evaluate
!                       the coefficients up to.
!           extend      If 1, return a grid that contains an additional column
!                       and row corresponding to 360 E longitude and 90 S
!                       latitude, respectively.
!
!       OPTIONAL (OUT)
!           exitstatus  If present, instead of executing a STOP when an error
!                       is encountered, the variable exitstatus will be
!                       returned describing the error.
!                       0 = No errors;
!                       1 = Improper dimensions of input array;
!                       2 = Improper bounds for input variable;
!                       3 = Error allocating memory;
!                       4 = File IO error.
!
!   Notes:
!       1.  If lmax is greater than the the maximum spherical harmonic
!           degree of the input coefficients, then the coefficients will be
!           zero padded.
!       2.  Latitude is geocentric latitude.
!
!   Copyright (c) 2005-2019, SHTOOLS
!   All rights reserved.
!
!------------------------------------------------------------------------------
    use FFTW3
    use SHTOOLS, only: CSPHASE_DEFAULT
    use ftypes
    use, intrinsic :: iso_c_binding

    implicit none

    complex(dp), intent(in) :: cilm(:,:,:)
    complex(dp), intent(out) :: griddh(:,:)
    integer, intent(in) :: lmax
    integer, intent(out) :: n
    integer, intent(in), optional :: norm, sampling, csphase, lmax_calc, extend
    integer, intent(out), optional :: exitstatus
    integer :: l, m, i, l1, m1, lmax_comp, i_eq, i_s, astat(4), lnorm, nlong, &
               nlat_out, nlong_out, phase, extend_grid
    real(dp) :: pi, theta, scalef, rescalem, u, p, pmm, pm1, pm2, z
    complex(dp) :: coef(4*lmax+4), coefs(4*lmax+4), tempc, grid(4*lmax+4), &
                   grids(4*lmax+4)
    type(C_PTR) :: plan, plans
    real(dp), save, allocatable :: ff1(:,:), ff2(:,:), sqr(:)
    integer(int1), save, allocatable :: fsymsign(:,:)
    integer, save :: lmax_old = 0, norm_old = 0

!$OMP   threadprivate(ff1, ff2, sqr, fsymsign, lmax_old, norm_old)

    if (present(exitstatus)) exitstatus = 0

    n = 2 * lmax + 2

    if (present(sampling)) then
        if (sampling == 1) then
            nlong = n
        else if (sampling == 2) then
            nlong = 2 * n
        else
            print*, "Error --- MakeGridDHC"
            print*, "Optional parameter SAMPLING must be 1 (N by N) " // &
                    "or 2 (N by 2N)."
            print*, "Input value is ", sampling
            if (present(exitstatus)) then
                exitstatus = 2
                return
            else
                stop
            end if
        end if
    else
        nlong = n
    end if

    if (present(extend)) then
        if (extend == 0) then
            extend_grid = 0
            nlat_out = n
            nlong_out = nlong
        else if (extend == 1) then
            extend_grid = 1
            nlat_out = n + 1
            nlong_out = nlong + 1
        else
            print*, "Error --- MakeGridDHC"
            print*, "Optional parameter EXTEND must be 0 or 1."
            print*, "Input value is ", extend
            if (present(exitstatus)) then
                exitstatus = 2
                return
            else
                stop
            end if
        end if
    else
        extend_grid = 0
        nlat_out = n
        nlong_out = nlong
    end if

    if (size(cilm(:,1,1)) < 2) then
        print*, "Error --- MakeGridDHC"
        print*, "CILM must be dimensioned as (2, *, *)."
        print*, "Input dimension is ", size(cilm(:,1,1)), size(cilm(1,:,1)), &
                size(cilm(1,1,:))
        if (present(exitstatus)) then
            exitstatus = 1
            return
        else
            stop
        end if
    end if

    if (size(griddh(:,1)) < nlat_out .or. size(griddh(1,:)) < nlong_out) then
        print*, "Error --- MakeGridDHC"
        print*, "GRIDDHC must be dimensioned as: ", nlat_out, nlong_out
        print*, "Input dimension is ", size(griddh(:,1)), &
                size(griddh(1,:))
        if (present(exitstatus)) then
            exitstatus = 1
            return
        else
            stop
        end if
    end if

    if (present(norm)) then
        if (norm > 4 .or. norm < 1) then
            print*, "Error --- MakeGridDHC"
            print*, "Parameter NORM must be 1 (geodesy), 2 (Schmidt), " // &
                    "3 (unnormalized), or 4 (orthonormalized)."
            print*, "Input value is ", norm
            if (present(exitstatus)) then
                exitstatus = 2
                return
            else
                stop
            end if
        end if

        lnorm = norm

    else
        lnorm = 1

    end if

    if (present(csphase)) then
        if (csphase /= -1 .and. csphase /= 1) then
            print*, "Error --- MakeGridDHC"
            print*, "CSPHASE must be 1 (exclude) or -1 (include)"
            print*, "Input valuse is ", csphase
            if (present(exitstatus)) then
                exitstatus = 2
                return
            else
                stop
            end if

        else
            phase = csphase

        end if
    else
        phase = CSPHASE_DEFAULT

    end if

    pi = acos(-1.0_dp)

    scalef = 1.0e-280_dp

    if (present(lmax_calc)) then
        if (lmax_calc > lmax) then
            print*, "Error --- MakeGridDHC"
            print*, "LMAX_CALC must be less than or equal to LMAX."
            print*, "LMAX = ", lmax
            print*, "LMAX_CALC = ", lmax_calc
            if (present(exitstatus)) then
                exitstatus = 2
                return
            else
                stop
            end if

        else
            lmax_comp = min(lmax, size(cilm(1,1,:))-1, size(cilm(1,:,1))-1, &
                            lmax_calc)

        end if
    else
        lmax_comp = min(lmax, size(cilm(1,1,:))-1, size(cilm(1,:,1))-1)

    end if

    !--------------------------------------------------------------------------
    !
    !   Calculate recursion constants used in computing the Legendre functions.
    !
    !--------------------------------------------------------------------------
    if (lmax_comp /= lmax_old .or. lnorm /= norm_old) then

        if (allocated (sqr)) deallocate (sqr)
        if (allocated (ff1)) deallocate (ff1)
        if (allocated (ff2)) deallocate (ff2)
        if (allocated (fsymsign)) deallocate (fsymsign)

        allocate (sqr(2*lmax_comp+1), stat=astat(1))
        allocate (ff1(lmax_comp+1, lmax_comp+1), stat=astat(2))
        allocate (ff2(lmax_comp+1, lmax_comp+1), stat=astat(3))
        allocate (fsymsign(lmax_comp+1, lmax_comp+1), stat=astat(4))

        if (sum(astat(1:4)) /= 0) then
            print*, "Error --- MakeGridDHC"
            print*, "Problem allocating arrays SQR, FF1, FF2, or FSYMSIGN", &
                    astat(1), astat(2), astat(3), astat(4)
            if (present(exitstatus)) then
                exitstatus = 3
                return
            else
                stop
            end if
        end if

        !----------------------------------------------------------------------
        !
        !   Calculate signs used for symmetry of Legendre functions about
        !   equator.
        !
        !----------------------------------------------------------------------
        do l = 0, lmax_comp, 1
            do m = 0, l, 1
                if (mod(l-m, 2) == 0) then
                    fsymsign(l+1, m+1) = 1

                else
                    fsymsign(l+1, m+1) = -1

                end if

            end do

        end do

        !----------------------------------------------------------------------
        !
        !   Precompute square roots of integers that are used several times.
        !
        !----------------------------------------------------------------------
        do l = 1, 2 * lmax_comp + 1
            sqr(l) = sqrt(dble(l))
        end do

        !----------------------------------------------------------------------
        !
        !   Precompute multiplicative factors used in recursion relationships
        !       P(l,m) = x*f1(l,m)*P(l-1,m) - P(l-2,m)*f2(l,m)
        !       k = l*(l+1)/2 + m + 1
        !   Note that prefactors are not used for the case when m=l as a
        !   different recursion is used. Furthermore, for m=l-1, Plmbar(l-2,m)
        !   is assumed to be zero.
        !
        !----------------------------------------------------------------------
        select case (lnorm)

            case (1,4)

                if (lmax_comp /= 0) then
                    ff1(2,1) = sqr(3)
                    ff2(2,1) = 0.0_dp
                end if

                do l = 2, lmax_comp, 1
                    ff1(l+1,1) = sqr(2*l-1) * sqr(2*l+1) / dble(l)
                    ff2(l+1,1) = dble(l-1) * sqr(2*l+1) / sqr(2*l-3) / dble(l)

                    do m = 1, l-2, 1
                        ff1(l+1,m+1) = sqr(2*l+1) * sqr(2*l-1) / sqr(l+m) &
                                       / sqr(l-m)
                        ff2(l+1,m+1) = sqr(2*l+1) * sqr(l-m-1) * sqr(l+m-1) &
                                       / sqr(2*l-3) / sqr(l+m) / sqr(l-m)
                    end do

                    ff1(l+1,l) = sqr(2*l+1) * sqr(2*l-1) / sqr(l+m) / sqr(l-m)
                    ff2(l+1,l) = 0.0_dp

                end do

            case (2)

                if (lmax_comp /= 0) then
                    ff1(2,1) = 1.0_dp
                    ff2(2,1) = 0.0_dp
                end if

                do l = 2, lmax_comp, 1
                    ff1(l+1,1) = dble(2*l-1) / dble(l)
                    ff2(l+1,1) = dble(l-1) / dble(l)

                    do m = 1, l-2, 1
                        ff1(l+1,m+1) = dble(2*l-1) / sqr(l+m) / sqr(l-m)
                        ff2(l+1,m+1) = sqr(l-m-1) * sqr(l+m-1) / sqr(l+m) &
                                       / sqr(l-m)
                    end do

                    ff1(l+1,l)= dble(2*l-1) / sqr(l+m) / sqr(l-m)
                    ff2(l+1,l) = 0.0_dp

                end do

            case (3)

                do l = 1, lmax_comp, 1
                    ff1(l+1,1) = dble(2*l-1) / dble(l)
                    ff2(l+1,1) = dble(l-1) / dble(l)

                    do m = 1, l-1, 1
                        ff1(l+1,m+1) = dble(2*l-1) / dble(l-m)
                        ff2(l+1,m+1) = dble(l+m-1) / dble(l-m)
                    end do

                end do

        end select

        lmax_old = lmax_comp
        norm_old = lnorm

    end if

    !--------------------------------------------------------------------------
    !
    !   Do special case of lmax_comp = 0
    !
    !--------------------------------------------------------------------------
    if (lmax_comp == 0) then

        select case (lnorm)
            case (1,2,3); pm2 = 1.0_dp
            case (4); pm2 = 1.0_dp / sqrt(4.0_dp * pi)
        end select

        griddh(1:nlat_out, 1:nlong_out) = cilm(1,1,1) * pm2

        return

    end if

    !--------------------------------------------------------------------------
    !
    !   Create generic plan for grid and grids.
    !
    !--------------------------------------------------------------------------
    plan = fftw_plan_dft_1d(nlong, coef(1:nlong), grid(1:nlong), &
                            FFTW_BACKWARD, FFTW_MEASURE)
    plans = fftw_plan_dft_1d(nlong, coefs(1:nlong), grids(1:nlong), &
                             FFTW_BACKWARD, FFTW_MEASURE)

    !--------------------------------------------------------------------------
    !
    !   Determine Clms one l at a time by intergrating over latitude.
    !
    !--------------------------------------------------------------------------
    i_eq = n/2 + 1  ! Index correspondong to zero latitude

    ! First do equator
    z = 0.0_dp
    u = 1.0_dp

    coef(1:nlong) = cmplx(0.0_dp, 0.0_dp, dp)

    select case (lnorm)
        case (1,2,3); pm2 = 1.0_dp
        case (4); pm2 = 1.0_dp / sqrt(4.0_dp * pi)
    end select

    coef(1) = coef(1) + cilm(1,1,1) * pm2

    do l = 2, lmax_comp, 2
        l1 = l + 1
        p = - ff2(l1,1) * pm2
        pm2 = p
        coef(1) = coef(1) + cilm(1,l1,1) * p
    end do

    select case (lnorm)
        case (1,2);  pmm = scalef
        case (3);    pmm = scalef
        case (4);    pmm = scalef / sqrt(4.0_dp * pi)
    end select

    rescalem = 1.0_dp / scalef

    do m = 1, lmax_comp-1, 1
        m1 = m + 1

        select case (lnorm)
            case (1,4)
                pmm = phase * pmm * sqr(2*m+1) / sqr(2*m)
                pm2 = pmm
            case (2)
                pmm = phase * pmm * sqr(2*m+1) / sqr(2*m)
                pm2 = pmm / sqr(2*m+1)
            case (3)
                pmm = phase * pmm * dble(2*m-1)
                pm2 = pmm
        end select

        coef(m1) = coef(m1) + cilm(1,m1,m1) * pm2
        coef(nlong-(m-1)) = coef(nlong-(m-1)) + cilm(2,m1,m1) * pm2

        do l = m + 2, lmax_comp, 2
            l1 = l + 1
            p = - ff2(l1,m1) * pm2
            coef(m1) = coef(m1) + cilm(1,l1,m1) * p
            coef(nlong-(m-1)) = coef(nlong-(m-1)) + cilm(2,l1,m1) * p
            pm2 = p
        end do

        coef(m1) = coef(m1) * rescalem
        coef(nlong-(m-1)) = coef(nlong-(m-1)) * rescalem * ((-1)**mod(m,2))

    end do

    select case (lnorm)
        case (1, 4)
            pmm = phase * pmm * sqr(2*lmax_comp+1) / sqr(2*lmax_comp) * rescalem
        case (2)
            pmm = phase * pmm / sqr(2*lmax_comp) * rescalem
        case (3)
            pmm = phase * pmm * (2*lmax_comp-1) * rescalem
    end select

    coef(lmax_comp+1) = coef(lmax_comp+1) + cilm(1,lmax_comp+1,lmax_comp+1) &
                        * pmm
    coef(nlong-(lmax_comp-1)) = coef(nlong-(lmax_comp-1)) &
                                + cilm(2,lmax_comp+1,lmax_comp+1) &
                                * pmm * ((-1)**mod(lmax_comp,2))

    call fftw_execute_dft(plan, coef, grid)

    griddh(i_eq,1:nlong) = grid(1:nlong)

    do i = 1, i_eq - 1, 1

        i_s = 2 * i_eq - i

        theta = pi * dble(i-1) / dble(n)
        z = cos(theta)
        u = sqrt( (1.0_dp-z) * (1.0_dp+z) )

        coef(1:nlong) = cmplx(0.0_dp, 0.0_dp, dp)
        coefs(1:nlong) = cmplx(0.0_dp, 0.0_dp, dp)

        select case (lnorm)
            case (1, 2, 3); pm2 = 1.0_dp
            case (4); pm2 = 1.0_dp / sqrt(4.0_dp * pi)
        end select

        tempc = cilm(1,1,1) * pm2
        coef(1) = coef(1) + tempc
        coefs(1) = coefs(1) + tempc     ! fsymsign is always 1 for l=m=0

        pm1 = ff1(2,1) * z * pm2
        tempc = cilm(1,2,1) * pm1
        coef(1) = coef(1) + tempc
        coefs(1) = coefs(1) - tempc     ! fsymsign = -1

        do l = 2, lmax_comp, 1
            l1 = l + 1
            p = ff1(l1,1) * z * pm1 - ff2(l1,1) * pm2
            tempc = cilm(1,l1,1) * p
            coef(1) = coef(1) + tempc
            coefs(1) = coefs(1) + tempc * fsymsign(l1,1)
            pm2 = pm1
            pm1 = p
        end do

        select case (lnorm)
            case (1, 2); pmm = scalef
            case (3);    pmm = scalef
            case (4);    pmm = scalef / sqrt(4.0_dp * pi)
        end select

        rescalem = 1.0_dp / scalef

        do m = 1, lmax_comp-1, 1
            m1 = m + 1
            rescalem = rescalem * u

            select case (lnorm)
                case (1, 4)
                    pmm = phase * pmm * sqr(2*m+1) / sqr(2*m)
                    pm2 = pmm
                case (2)
                    pmm = phase * pmm * sqr(2*m+1) / sqr(2*m)
                    pm2 = pmm / sqr(2*m+1)
                case (3)
                    pmm = phase * pmm * dble(2*m-1)
                    pm2 = pmm
            end select

            tempc = cilm(1,m1,m1) * pm2
            coef(m1) = coef(m1) + tempc
            coefs(m1) = coefs(m1) + tempc
            tempc = cilm(2,m1,m1) * pm2
            coef(nlong-(m-1)) = coef(nlong-(m-1)) + tempc
            coefs(nlong-(m-1)) = coefs(nlong-(m-1)) + tempc
            ! fsymsign = 1

            pm1 = z * ff1(m1+1,m1) * pm2

            tempc = cilm(1,m1+1,m1) * pm1
            coef(m1) = coef(m1) + tempc 
            coefs(m1) = coefs(m1) - tempc
            tempc = cilm(2,m1+1,m1) * pm1
            coef(nlong-(m-1)) = coef(nlong-(m-1)) + tempc
            coefs(nlong-(m-1)) = coefs(nlong-(m-1)) - tempc
            ! fsymsign = -1

            do l = m + 2, lmax_comp, 1
                l1 = l + 1
                p = z * ff1(l1,m1) * pm1 - ff2(l1,m1) * pm2
                pm2 = pm1
                pm1 = p
                tempc = cilm(1,l1,m1) * p
                coef(m1) = coef(m1) + tempc
                coefs(m1) = coefs(m1) + tempc * fsymsign(l1,m1)
                tempc = cilm(2,l1,m1) * p
                coef(nlong-(m-1)) = coef(nlong-(m-1)) + tempc
                coefs(nlong-(m-1)) = coefs(nlong-(m-1)) + tempc &
                                    * fsymsign(l1,m1)
            end do

            coef(m1) = coef(m1) * rescalem
            coefs(m1) = coefs(m1) * rescalem
            coef(nlong-(m-1)) = coef(nlong-(m-1)) * rescalem * ((-1)**mod(m,2))
            coefs(nlong-(m-1)) = coefs(nlong-(m-1)) * &
                                 rescalem * ((-1)**mod(m,2))

        end do

        rescalem = rescalem * u

        select case (lnorm)
            case (1, 4)
                pmm = phase * pmm * sqr(2*lmax_comp+1) / sqr(2*lmax_comp) &
                      * rescalem
            case(2)
                pmm = phase * pmm / sqr(2*lmax_comp) * rescalem
            case(3)
                pmm = phase * pmm * dble(2*lmax_comp-1) * rescalem
        end select

        tempc = cilm(1,lmax_comp+1,lmax_comp+1) * pmm
        coef(lmax_comp+1) = coef(lmax_comp+1) + tempc
        coefs(lmax_comp+1) = coefs(lmax_comp+1) + tempc
        tempc = cilm(2,lmax_comp+1,lmax_comp+1) * pmm * ((-1)**mod(lmax_comp,2))
        coef(nlong-(lmax_comp-1)) = coef(nlong-(lmax_comp-1)) + tempc
        coefs(nlong-(lmax_comp-1)) = coefs(nlong-(lmax_comp-1)) + tempc
        ! fsymsign = 1

        call fftw_execute_dft(plan, coef, grid)
        griddh(i,1:nlong) = grid(1:nlong)

        ! don't compute value for south pole when extend = 0.
        if (.not. (i == 1 .and. extend_grid == 0) ) then
            call fftw_execute_dft(plans, coefs, grids)
            griddh(i_s,1:nlong) = grids(1:nlong)
        end if

    end do

    if (extend_grid == 1) then
        griddh(1:nlat_out, nlong_out) = griddh(1:nlat_out, 1)
    end if

    call fftw_destroy_plan(plan)
    call fftw_destroy_plan(plans)

end subroutine MakeGridDHC
