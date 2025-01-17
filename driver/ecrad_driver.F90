! ecrad_driver.F90 - Driver for offline ECRAD radiation scheme
!
! (C) Copyright 2014- ECMWF.
!
! This software is licensed under the terms of the Apache Licence Version 2.0
! which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
!
! In applying this licence, ECMWF does not waive the privileges and immunities
! granted to it by virtue of its status as an intergovernmental organisation
! nor does it submit to any jurisdiction.
!
! Author:  Robin Hogan
! Email:   r.j.hogan@ecmwf.int
!
! ECRAD is the radiation scheme used in the ECMWF Integrated
! Forecasting System in cycle 43R3 and later. Several solvers are
! available, including McICA, Tripleclouds and SPARTACUS (the Speedy
! Algorithm for Radiative Transfer through Cloud Sides, a modification
! of the two-stream formulation of shortwave and longwave radiative
! transfer to account for 3D radiative effects). Gas optical
! properties are provided by the RRTM-G gas optics scheme.

! This program takes three arguments:
! 1) Namelist file to configure the radiation calculation
! 2) Name of a NetCDF file containing one or more atmospheric profiles
! 3) Name of output NetCDF file

program ecrad_driver

  ! --------------------------------------------------------
  ! Section 1: Declarations
  ! --------------------------------------------------------
  use parkind1,                 only : jprb, jprd ! Working/double precision

  use radiation_io,             only : nulout
  use radiation_interface,      only : setup_radiation, radiation, set_gas_units
  use radiation_config,         only : config_type
  use radiation_single_level,   only : single_level_type
  use radiation_thermodynamics, only : thermodynamics_type
  use radiation_gas,            only : gas_type, &
       &   IVolumeMixingRatio, IMassMixingRatio, &
       &   IH2O, ICO2, IO3, IN2O, ICO, ICH4, IO2, ICFC11, ICFC12, &
       &   IHCFC22, ICCl4, GasName, GasLowerCaseName, NMaxGases
  use radiation_cloud,          only : cloud_type
  use radiation_aerosol,        only : aerosol_type
  use radiation_flux,           only : flux_type
  use radiation_save,           only : save_fluxes, save_net_fluxes, &
       &                               save_inputs, save_sw_diagnostics
  use radiation_general_cloud_optics, only : save_general_cloud_optics
  use ecrad_driver_config,      only : driver_config_type
  use ecrad_driver_read_input,  only : read_input
  use easy_netcdf
  use print_matrix_mod,         only : print_matrix

  use mpi
  use ecrad_binding
  use output_type_factory

  implicit none

  ! Uncomment this if you want to use the "satur" routine below
!#include "satur.intfb.h"
  
  ! The NetCDF file containing the input profiles
  type(netcdf_file)         :: file

  ! Derived types for the inputs to the radiation scheme
  type(config_type)         :: config
  type(single_level_type)   :: single_level
  type(thermodynamics_type) :: thermodynamics
  type(gas_type)            :: gas
  type(cloud_type)          :: cloud
  type(aerosol_type)        :: aerosol

  ! Configuration specific to this driver
  type(driver_config_type)  :: driver_config

  ! Derived type containing outputs from the radiation scheme
  type(flux_type)           :: flux

  integer :: ncol, nlev         ! Number of columns and levels
  integer :: istartcol, iendcol ! Range of columns to process

  ! Name of file names specified on command line
  character(len=512) :: file_name
  integer            :: istatus ! Result of command_argument_count

  ! For parallel processing of multiple blocks
  integer :: jblock, nblock ! Block loop index and number

  ! Mapping matrix for shortwave spectral diagnostics
  real(jprb), allocatable :: sw_diag_mapping(:,:)
  
#ifndef NO_OPENMP
  ! OpenMP functions
  integer, external :: omp_get_thread_num
  real(kind=jprd), external :: omp_get_wtime
  ! Start/stop time in seconds
  real(kind=jprd) :: tstart, tstop
#endif

  ! For demonstration of get_sw_weights later on
  ! Ultraviolet weightings
  !integer    :: nweight_uv
  !integer    :: iband_uv(100)
  !real(jprb) :: weight_uv(100)
  ! Photosynthetically active radiation weightings
  !integer    :: nweight_par
  !integer    :: iband_par(100)
  !real(jprb) :: weight_par(100)

  ! Loop index for repeats (for benchmarking)
  integer :: jrepeat

  ! Are any variables out of bounds?
  logical :: is_out_of_bounds

!  integer    :: iband(20), nweights
!  real(jprb) :: weight(20)

  ! MPI variables
  integer                                :: IREQUIRED
  integer                                :: IPROVIDED
  integer                                :: IERR
  integer                                :: ECRAD_COMM ! Not use, just to mimic IFS splited comm
  integer                                :: MPI_SIZE, RANK
  logical(1)                             :: L_stop_inferer

  ! AI4Sim binding
  type(ecrad_output_struct)                :: solver_output
  type(inferer_output_struct)              :: solver_input
  type(ecrad_binding_type)                 :: solver_binding
  type(ecrad_output_struct), allocatable   :: solver_data(:)
  type(inferer_output_struct), allocatable :: solver_buffer(:)
  ! Generic variables
  integer                                :: dt(8)
  character(len=4)                       :: rank_string
  character(len=512)                     :: output_file_name
  integer                                :: extension_index
  integer                                :: n_solver_proc, n_inferer, inferer_rank, proc_num

  ! --------------------------------------------------------
  ! Section 2: Configure
  ! --------------------------------------------------------

  ! MPI INIT to mimic IFS
  IREQUIRED = MPI_THREAD_MULTIPLE
  IPROVIDED = MPI_THREAD_SINGLE
  CALL MPI_INIT_THREAD(IREQUIRED,IPROVIDED,IERR)
  CALL MPI_Barrier(MPI_COMM_WORLD, IERR)
  CALL MPI_COMM_SIZE(MPI_COMM_WORLD, MPI_SIZE, IERR)
  CALL MPI_COMM_RANK (MPI_COMM_WORLD, RANK, IERR)
  CALL MPI_COMM_SPLIT (MPI_COMM_WORLD, 1, RANK, ECRAD_COMM, IERR)
  CALL MPI_COMM_SIZE(ECRAD_COMM, n_solver_proc, IERR)

  ! Check program called with correct number of arguments
  if (command_argument_count() < 3) then
    stop 'Usage: ecrad config.nam input_file.nc output_file.nc'
  end if

  ! Use namelist to configure the radiation calculation
  call get_command_argument(1, file_name, status=istatus)
  if (istatus /= 0) then
    stop 'Failed to read name of namelist file as string of length < 512'
  end if

  ! Read "radiation" namelist into radiation configuration type
  call config%read(file_name=file_name)

  ! Read "radiation_driver" namelist into radiation driver config type
  call driver_config%read(file_name)

  if (driver_config%iverbose >= 2) then
    write(nulout,'(a)') '-------------------------- OFFLINE ECRAD RADIATION SCHEME --------------------------'
    write(nulout,'(a)') 'Copyright (C) 2014- ECMWF'
    write(nulout,'(a)') 'Contact: Robin Hogan (r.j.hogan@ecmwf.int)'
#ifdef SINGLE_PRECISION
    write(nulout,'(a)') 'Floating-point precision: single'
#else
    write(nulout,'(a)') 'Floating-point precision: double'
#endif
    call config%print(driver_config%iverbose)
  end if

  ! Albedo/emissivity intervals may be specified like this
  !call config%define_sw_albedo_intervals(6, &
  !     &  [0.25e-6_jprb, 0.44e-6_jprb, 0.69e-6_jprb, &
  !     &     1.19_jprb, 2.38e-6_jprb], [1,2,3,4,5,6], &
  !     &   do_nearest=.false.)
  !call config%define_lw_emiss_intervals(3, &
  !     &  [8.0e-6_jprb, 13.0e-6_jprb], [1,2,1], &
  !     &   do_nearest=.false.)

  ! If monochromatic aerosol properties are required, then the
  ! wavelengths can be specified (in metres) as follows - these can be
  ! whatever you like for the general aerosol optics, but must match
  ! the monochromatic values in the aerosol input file for the older
  ! aerosol optics
  !call config%set_aerosol_wavelength_mono( &
  !     &  [3.4e-07_jprb, 3.55e-07_jprb, 3.8e-07_jprb, 4.0e-07_jprb, 4.4e-07_jprb, &
  !     &   4.69e-07_jprb, 5.0e-07_jprb, 5.32e-07_jprb, 5.5e-07_jprb, 6.45e-07_jprb, &
  !     &   6.7e-07_jprb, 8.0e-07_jprb, 8.58e-07_jprb, 8.65e-07_jprb, 1.02e-06_jprb, &
  !     &   1.064e-06_jprb, 1.24e-06_jprb, 1.64e-06_jprb, 2.13e-06_jprb, 1.0e-05_jprb])

  ! Setup the radiation scheme: load the coefficients for gas and
  ! cloud optics, currently from RRTMG
  call setup_radiation(config)

  n_inferer = MPI_SIZE - n_solver_proc;
  inferer_rank = MOD(RANK, n_inferer) + n_solver_proc;
  proc_num = (RANK / n_inferer);
  if (proc_num == 0) then
      ! Send to the good  inferer the solver processes infos
      call solver_binding % start_inferer(n_solver_proc, inferer_rank)
  end if

  ! Initialize AI4Sim binding
    call solver_binding % new()
    call solver_binding % initialize(solver_output, solver_input)

  if (proc_num == 0) then
    ! Request inferer
    L_stop_inferer = .false.
    call solver_binding % stop_inferer(L_stop_inferer, inferer_rank)
  end if

  ! Demonstration of how to get weights for UV and PAR fluxes
  !if (config%do_sw) then
  !  call config%get_sw_weights(0.2e-6_jprb, 0.4415e-6_jprb,&
  !       &  nweight_uv, iband_uv, weight_uv,&
  !       &  'ultraviolet')
  !  call config%get_sw_weights(0.4e-6_jprb, 0.7e-6_jprb,&
  !       &  nweight_par, iband_par, weight_par,&
  !       &  'photosynthetically active radiation, PAR')
  !end if

  ! Optionally compute shortwave spectral diagnostics in
  ! user-specified wavlength intervals
  if (driver_config%n_sw_diag > 0) then
    if (.not. config%do_surface_sw_spectral_flux) then
      stop 'Error: shortwave spectral diagnostics require do_surface_sw_spectral_flux=true'
    end if
    call config%get_sw_mapping(driver_config%sw_diag_wavelength_bound(1:driver_config%n_sw_diag+1), &
         &  sw_diag_mapping, 'user-specified diagnostic intervals')
    !if (driver_config%iverbose >= 3) then
    !  call print_matrix(sw_diag_mapping, 'Shortwave diagnostic mapping', nulout)
    !end if
  end if
  
  if (driver_config%do_save_aerosol_optics) then
    call config%aerosol_optics%save('aerosol_optics.nc', iverbose=driver_config%iverbose)
  end if

  if (driver_config%do_save_cloud_optics .and. config%use_general_cloud_optics) then
    call save_general_cloud_optics(config, 'hydrometeor_optics', iverbose=driver_config%iverbose)
  end if

  ! --------------------------------------------------------
  ! Section 3: Read input data file
  ! --------------------------------------------------------

  ! Get NetCDF input file name
  call get_command_argument(2, file_name, status=istatus)
  if (istatus /= 0) then
    stop 'Failed to read name of input NetCDF file as string of length < 512'
  end if

  ! Open the file and configure the way it is read
  call file%open(trim(file_name), iverbose=driver_config%iverbose)

  ! Get NetCDF output file name
  call get_command_argument(3, file_name, status=istatus)
  if (istatus /= 0) then
    stop 'Failed to read name of output NetCDF file as string of length < 512'
  end if

  ! 2D arrays are assumed to be stored in the file with height varying
  ! more rapidly than column index. Specifying "true" here transposes
  ! all 2D arrays so that the column index varies fastest within the
  ! program.
  call file%transpose_matrices(.true.)

  ! Read input variables from NetCDF file
  call read_input(file, config, driver_config, ncol, nlev, &
       &          single_level, thermodynamics, &
       &          gas, cloud, aerosol)

  ! Close input file
  call file%close()

  ! Compute seed from skin temperature residual
  !  single_level%iseed = int(1.0e9*(single_level%skin_temperature &
  !       &                            -int(single_level%skin_temperature)))

  ! Set first and last columns to process
  if (driver_config%iendcol < 1 .or. driver_config%iendcol > ncol) then
    driver_config%iendcol = ncol
  end if

  if (driver_config%istartcol > driver_config%iendcol) then
    write(nulout,'(a,i0,a,i0,a,i0,a)') '*** Error: requested column range (', &
         &  driver_config%istartcol, &
         &  ' to ', driver_config%iendcol, ') is out of the range in the data (1 to ', &
         &  ncol, ')'
    stop 1
  end if
  
  ! Store inputs
  if (driver_config%do_save_inputs) then
    call save_inputs('inputs.nc', config, single_level, thermodynamics, &
         &                gas, cloud, aerosol, &
         &                lat=spread(0.0_jprb,1,ncol), &
         &                lon=spread(0.0_jprb,1,ncol), &
         &                iverbose=driver_config%iverbose)
  end if

  ! Use parameters from the file to finalize the initialization of AI4Sim
  allocate(solver_buffer(driver_config % nblocksize))
  allocate(solver_data(driver_config % nblocksize))

  call solver_binding % connect(solver_buffer, driver_config % nblocksize, driver_config % nblocksize)
  call solver_binding % fence()

  ! --------------------------------------------------------
  ! Section 4: Call radiation scheme
  ! --------------------------------------------------------

  ! If we use it, set the input of the inferer before they will be modiified by eCrad preprocessing.
  if (.not.(driver_config%do_parallel)) then
      istartcol = RANK * driver_config % nblocksize + 1

      do jblock = 1, driver_config % nblocksize
        ! Create data structure for AI4Sim
        solver_output % skin_temperature = single_level % skin_temperature(istartcol + jblock - 1)
        solver_output % cos_solar_zenith_angle = single_level % cos_sza(istartcol + jblock - 1)
        solver_output % sw_albedo = (/single_level % sw_albedo(istartcol + jblock - 1,:)/)
        solver_output % sw_albedo_direct = (/single_level % sw_albedo_direct(istartcol + jblock - 1,:)/)
        solver_output % lw_emissivity = (/single_level % lw_emissivity(istartcol + jblock - 1,:)/)
        solver_output % solar_irradiance = single_level % solar_irradiance
        solver_output % q = (/gas % mixing_ratio(istartcol + jblock - 1,:,1)/)
        solver_output % o3_mmr = (/gas % mixing_ratio(istartcol + jblock - 1,:,3)/)
        solver_output % co2_vmr = (/gas % mixing_ratio(istartcol + jblock - 1,:,2)/)
        solver_output % n2o_vmr = (/gas % mixing_ratio(istartcol + jblock - 1,:,4)/)
        solver_output % ch4_vmr = (/gas % mixing_ratio(istartcol + jblock - 1,:,6)/)
        solver_output % o2_vmr = (/gas % mixing_ratio(istartcol + jblock - 1,:,7)/)
        solver_output % cfc11_vmr = (/gas % mixing_ratio(istartcol + jblock - 1,:,8)/)
        solver_output % cfc12_vmr = (/gas % mixing_ratio(istartcol + jblock - 1,:,9)/)
        solver_output % hcfc22_vmr = (/gas % mixing_ratio(istartcol + jblock - 1,:,10)/)
        solver_output % ccl4_vmr = (/gas % mixing_ratio(istartcol + jblock - 1,:,11)/)
        solver_output % cloud_fraction = (/cloud % fraction(istartcol + jblock - 1,:)/)
        solver_output % aerosol_mmr = reshape((/aerosol % mixing_ratio(istartcol + jblock - 1,:,:)/), &
                & shape(solver_output % aerosol_mmr))
        solver_output % q_liquid = (/cloud % q_liq(istartcol + jblock - 1,:)/)
        solver_output % q_ice = (/cloud % q_ice(istartcol + jblock - 1,:)/)
        solver_output % re_liquid = (/cloud % re_liq(istartcol + jblock - 1,:)/)
        solver_output % re_ice = (/cloud % re_ice(istartcol + jblock - 1,:)/)
        solver_output % temperature_hl = (/thermodynamics % temperature_hl(istartcol + jblock - 1,:)/)
        solver_output % pressure_hl = (/thermodynamics % pressure_hl(istartcol + jblock - 1,:)/)
        solver_output % overlap_param = (/cloud % overlap_param(istartcol + jblock - 1,:)/)

        ! Add data structure to the array
        solver_data(jblock) = solver_output
      end do
  end if

  if (driver_config%iverbose >= 5) then
      write(*, *) 'Min/Max skin_temperature        : ', single_level % skin_temperature(1)
      write(*, *) 'Min/Max cos_solar_zenith_angle  : ', single_level % cos_sza(1)
      write(*, *) 'Min/Max sw_albedo               : ', MINVAL((/single_level % sw_albedo(1,:)/)), ' ', &
              & MAXVAL((/single_level % sw_albedo(1,:)/))
      write(*, *) 'Min/Max sw_albedo_direct        : ', MINVAL((/single_level % sw_albedo_direct(1,:)/)), ' ', &
              & MAXVAL((/single_level % sw_albedo_direct(1,:)/))
      write(*, *) 'Min/Max lw_emissivity           : ', MINVAL((/single_level % lw_emissivity(1,:)/)), ' ', &
              & MAXVAL((/single_level % lw_emissivity(1,:)/))
      write(*, *) 'Min/Max solar_irradiance        : ', single_level % solar_irradiance
      write(*, *) 'Min/Max q                       : ', MINVAL((/gas % mixing_ratio(1,:,1)/)), ' ', &
              & MAXVAL((/gas % mixing_ratio(1,:,1)/))
      write(*, *) 'Min/Max o3_mmr                  : ', MINVAL((/gas % mixing_ratio(1,:,3)/)), ' ', &
              & MAXVAL((/gas % mixing_ratio(1,:,3)/))
      write(*, *) 'Min/Max co2_vmr                 : ', MINVAL((/gas % mixing_ratio(1,:,2)/)), ' ', &
              & MAXVAL((/gas % mixing_ratio(1,:,2)/))
      write(*, *) 'Min/Max n2o_vmr                 : ', MINVAL((/gas % mixing_ratio(1,:,4)/)), ' ', &
              & MAXVAL((/gas % mixing_ratio(1,:,4)/))
      write(*, *) 'Min/Max ch4_vmr                 : ', MINVAL((/gas % mixing_ratio(1,:,6)/)), ' ', &
              & MAXVAL((/gas % mixing_ratio(1,:,6)/))
      write(*, *) 'Min/Max o2_vmr                  : ', MINVAL((/gas % mixing_ratio(1,:,7)/)), ' ', &
              & MAXVAL((/gas % mixing_ratio(1,:,7)/))
      write(*, *) 'Min/Max cfc11_vmr               : ', MINVAL((/gas % mixing_ratio(1,:,8)/)), ' ', &
              & MAXVAL((/gas % mixing_ratio(1,:,8)/))
      write(*, *) 'Min/Max cfc12_vmr               : ', MINVAL((/gas % mixing_ratio(1,:,9)/)), ' ', &
              & MAXVAL((/gas % mixing_ratio(1,:,9)/))
      write(*, *) 'Min/Max hcfc22_vmr              : ', MINVAL((/gas % mixing_ratio(1,:,10)/)), ' ', &
              & MAXVAL((/gas % mixing_ratio(1,:,10)/))
      write(*, *) 'Min/Max ccl4_vmr                : ', MINVAL((/gas % mixing_ratio(1,:,11)/)), ' ', &
              & MAXVAL((/gas % mixing_ratio(1,:,11)/))
      write(*, *) 'Min/Max cloud_fraction          : ', MINVAL((/cloud % fraction(1,:)/)), ' ', &
              & MAXVAL((/cloud % fraction(1,:)/))
      write(*, *) 'Min/Max aerosol_mmr             : ', MINVAL((/aerosol % mixing_ratio(1,:,:)/)), ' ', &
              & MAXVAL((/aerosol % mixing_ratio(1,:,:)/))
      write(*, *) 'Min/Max q_liquid                : ', MINVAL((/cloud % q_liq(1,:)/)), ' ', &
              & MAXVAL((/cloud % q_liq(1,:)/))
      write(*, *) 'Min/Max q_ice                   : ', MINVAL((/cloud % q_ice(1,:)/)), ' ', &
              & MAXVAL((/cloud % q_ice(1,:)/))
      write(*, *) 'Min/Max re_liquid               : ', MINVAL((/cloud % re_liq(1,:)/)), ' ', &
              & MAXVAL((/cloud % re_liq(1,:)/))
      write(*, *) 'Min/Max re_ice                  : ', MINVAL((/cloud % re_ice(1,:)/)), ' ', &
              & MAXVAL((/cloud % re_ice(1,:)/))
      write(*, *) 'Min/Max temperature_hl          : ', MINVAL((/thermodynamics % temperature_hl(1,:)/)), ' ', &
              & MAXVAL((/thermodynamics % temperature_hl(1,:)/))
      write(*, *) 'Min/Max pressure_hl             : ', MINVAL((/thermodynamics % pressure_hl(1,:)/)), ' ', &
              & MAXVAL((/thermodynamics % pressure_hl(1,:)/))
      write(*, *) 'Min/Max overlap_param           : ', MINVAL((/cloud % overlap_param(1,:)/)), ' ', &
              & MAXVAL((/cloud % overlap_param(1,:)/))
  end if

  ! Ensure the units of the gas mixing ratios are what is required
  ! by the gas absorption model
  call set_gas_units(config, gas)

  ! Compute saturation with respect to liquid (needed for aerosol
  ! hydration) call...
  call thermodynamics%calc_saturation_wrt_liquid(driver_config%istartcol,driver_config%iendcol)

  ! ...or alternatively use the "satur" function in the IFS (requires
  ! adding -lifs to the linker command line) but note that this
  ! computes saturation with respect to ice at colder temperatures,
  ! which is almost certainly incorrect
  !allocate(thermodynamics%h2o_sat_liq(ncol,nlev))
  !call satur(driver_config%istartcol, driver_config%iendcol, ncol, 1, nlev, .false., &
  !     0.5_jprb * (thermodynamics.pressure_hl(:,1:nlev)+thermodynamics.pressure_hl(:,2:nlev)), &
  !     0.5_jprb * (thermodynamics.temperature_hl(:,1:nlev)+thermodynamics.temperature_hl(:,2:nlev)), &
  !     thermodynamics%h2o_sat_liq, 2)
  
  ! Check inputs are within physical bounds, printing message if not
  is_out_of_bounds =     gas%out_of_physical_bounds(driver_config%istartcol, driver_config%iendcol, &
       &                                            driver_config%do_correct_unphysical_inputs) &
       & .or.   single_level%out_of_physical_bounds(driver_config%istartcol, driver_config%iendcol, &
       &                                            driver_config%do_correct_unphysical_inputs) &
       & .or. thermodynamics%out_of_physical_bounds(driver_config%istartcol, driver_config%iendcol, &
       &                                            driver_config%do_correct_unphysical_inputs) &
       & .or.          cloud%out_of_physical_bounds(driver_config%istartcol, driver_config%iendcol, &
       &                                            driver_config%do_correct_unphysical_inputs) &
       & .or.        aerosol%out_of_physical_bounds(driver_config%istartcol, driver_config%iendcol, &
       &                                            driver_config%do_correct_unphysical_inputs) 
  
  ! Allocate memory for the flux profiles, which may include arrays
  ! of dimension n_bands_sw/n_bands_lw, so must be called after
  ! setup_radiation
  call flux%allocate(config, 1, ncol, nlev)
  
  if (driver_config%iverbose >= 2) then
    write(nulout,'(a)')  'Performing radiative transfer calculations'
  end if
  
  ! Option of repeating calculation multiple time for more accurate
  ! profiling
#ifndef NO_OPENMP
  tstart = omp_get_wtime() 
#endif
  do jrepeat = 1,driver_config%nrepeat
    
    if (driver_config%do_parallel) then
      ! Run radiation scheme over blocks of columns in parallel
      
      ! Compute number of blocks to process
      nblock = (driver_config%iendcol - driver_config%istartcol &
           &  + driver_config%nblocksize) / driver_config%nblocksize
     
      !$OMP PARALLEL DO PRIVATE(istartcol, iendcol) SCHEDULE(RUNTIME)
      do jblock = 1, nblock
        ! Specify the range of columns to process.
        istartcol = (jblock-1) * driver_config%nblocksize &
             &    + driver_config%istartcol
        iendcol = min(istartcol + driver_config%nblocksize - 1, &
             &        driver_config%iendcol)
          
        if (driver_config%iverbose >= 3) then
#ifndef NO_OPENMP
          write(nulout,'(a,i0,a,i0,a,i0)')  'Thread ', omp_get_thread_num(), &
               &  ' processing columns ', istartcol, '-', iendcol
#else
          write(nulout,'(a,i0,a,i0)')  'Processing columns ', istartcol, '-', iendcol
#endif
        end if
        
        ! Call the ECRAD radiation scheme
        call radiation(ncol, nlev, istartcol, iendcol, config, &
             &  single_level, thermodynamics, gas, cloud, aerosol, flux)
        
      end do
      !$OMP END PARALLEL DO
      
    else
      iendcol = (RANK + 1) * driver_config % nblocksize

      if (driver_config%iverbose >= 3) then
        write(nulout,'(a,i0,a)')  'Processing ', (iendcol - istartcol + 1), ' columns'
        write(nulout,'(a,i0,a,i0)')  'Processing from column ', istartcol - 1, ' to column ', iendcol
      end if

      ! Put data into the inferer buffer
      call solver_binding % put(solver_data, driver_config % nblocksize, proc_num, inferer_rank)

      ! Wait for all the ecrad process to write into the inferer buffer
      call solver_binding % fence()

      ! Call the ECRAD radiation scheme
      call radiation(ncol, nlev, istartcol, iendcol, config, single_level, thermodynamics, gas, cloud, aerosol, flux)

      ! Wait for the inferer to process the input data and send back the results
      call solver_binding % fence()

      if (driver_config%iverbose >= 4) then
        call date_and_time(values=dt)
        write(*, '(i4, 5(a, i2.2), a, i3.3, a)') dt(1), '-', dt(2), '-', dt(3), ' ', dt(5), ':', dt(6), ':', dt(7), ',', dt(8), &
              & ' -- root -- INFO -- [SOLVER ] Getting first column results from inferer'
        write(*, *) 'I->S hr_sw         : ', solver_buffer(1) % hr_sw(:10)
        write(*, *) 'I->S hr_lw         : ', solver_buffer(1) % hr_lw(:10)
        write(*, *) 'I->S delta_sw_diff : ', solver_buffer(1) % delta_sw_diff(:10)
        write(*, *) 'I->S delta_sw_add  : ', solver_buffer(1) % delta_sw_add(:10)
        write(*, *) 'I->S delta_lw_diff : ', solver_buffer(1) % delta_lw_diff(:10)
        write(*, *) 'I->S delta_lw_add  : ', solver_buffer(1) % delta_lw_add(:10)
      end if


      ! Generate the output file name
        write(rank_string,'(I4)') RANK
        file_name = trim(file_name)
        extension_index = index(file_name, ".")
        output_file_name = file_name(1:extension_index-1)//'_origin_'//&
                &trim(adjustl(rank_string))//file_name(extension_index:len(file_name))

        ! Store the fluxes in the output file
        call save_fluxes(output_file_name, config, thermodynamics, flux, &
             &   iverbose=driver_config%iverbose, is_hdf5_file=driver_config%do_write_hdf5, &
             &   experiment_name=driver_config%experiment_name, &
             &   is_double_precision=driver_config%do_write_double_precision)

      ! Correct the radiative scheme results with the NN results
      if (driver_config%iverbose >= 3) then
        write(nulout,'(a,i0,a,i0)')  'Correct the radiative scheme results with the NN results.'
      end if
      do jblock = 1, driver_config % nblocksize
        flux % lw_up(istartcol + jblock - 1,:) = flux % lw_up(istartcol + jblock - 1,:) &
              & + (solver_buffer(jblock) % delta_lw_add(:) - solver_buffer(jblock) % delta_lw_diff(:)) / 2
        flux % lw_dn(istartcol + jblock - 1,:) = flux % lw_dn(istartcol + jblock - 1,:) &
                & + (solver_buffer(jblock) % delta_lw_add(:) + solver_buffer(jblock) % delta_lw_diff(:)) /2
        flux % sw_up(istartcol + jblock - 1,:) = flux % sw_up(istartcol + jblock - 1,:) &
                & + (solver_buffer(jblock) % delta_sw_add(:) - solver_buffer(jblock) % delta_sw_diff(:)) / 2
        flux % sw_dn(istartcol + jblock - 1,:) = flux % sw_dn(istartcol + jblock - 1,:) &
                & + (solver_buffer(jblock) % delta_sw_add(:) + solver_buffer(jblock) % delta_sw_diff(:)) / 2
      end do
    end if

#ifndef NO_OPENMP
  tstop = omp_get_wtime()
  write(nulout, '(a,g12.5,a)') 'Time elapsed in radiative transfer: ', tstop-tstart, ' seconds'
#endif

    ! --------------------------------------------------------
    ! Section 5: Check and save output
    ! --------------------------------------------------------

    is_out_of_bounds = flux%out_of_physical_bounds(driver_config%istartcol, driver_config%iendcol)

    ! Generate the output file name
    write(rank_string,'(I4)') RANK
    file_name = trim(file_name)
    extension_index = index(file_name, ".")
    output_file_name = file_name(1:extension_index-1)//'_'//&
            &trim(adjustl(rank_string))//file_name(extension_index:len(file_name))

    ! Store the fluxes in the output file
    if (.not. driver_config%do_save_net_fluxes) then
      call save_fluxes(output_file_name, config, thermodynamics, flux, &
            &   iverbose=driver_config%iverbose, is_hdf5_file=driver_config%do_write_hdf5, &
            &   experiment_name=driver_config%experiment_name, &
            &   is_double_precision=driver_config%do_write_double_precision)
    else
      call save_net_fluxes(output_file_name, config, thermodynamics, flux, &
            &   iverbose=driver_config%iverbose, is_hdf5_file=driver_config%do_write_hdf5, &
            &   experiment_name=driver_config%experiment_name, &
            &   is_double_precision=driver_config%do_write_double_precision)
    end if
  
    if (driver_config%n_sw_diag > 0) then
      ! Store spectral fluxes in user-defined intervals in a second
      ! output file
      call save_sw_diagnostics(driver_config%sw_diag_file_name, config, &
            &  driver_config%sw_diag_wavelength_bound(1:driver_config%n_sw_diag+1), &
            &  sw_diag_mapping, flux, iverbose=driver_config%iverbose, &
            &  is_hdf5_file=driver_config%do_write_hdf5, &
            &  experiment_name=driver_config%experiment_name, &
            &  is_double_precision=driver_config%do_write_double_precision)
    end if

    if (driver_config%iverbose >= 2) then
      write(nulout,'(a)') '------------------------------------------------------------------------------------'
    end if

    deallocate(solver_buffer)
    deallocate(solver_data)

    call solver_binding % disconnect()

  end do

  if (proc_num == 0) then
    ! Request inferer to stop
    L_stop_inferer = .true.
    call solver_binding % stop_inferer(L_stop_inferer, inferer_rank)
  end if

  call solver_binding % delete()

  ! Finalize MPI
  CALL MPI_FINALIZE(IERR)

end program ecrad_driver
