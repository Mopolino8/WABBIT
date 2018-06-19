subroutine check_redundant_nodes( params, lgt_block, hvy_block, hvy_neighbor, hvy_active, &
    hvy_n, stop_status, stage0, force_averaging )

!---------------------------------------------------------------------------------------------
! modules

!---------------------------------------------------------------------------------------------
! variables

    implicit none

    !> user defined parameter structure
    type (type_params), intent(in)      :: params
    !> light data array
    integer(kind=ik), intent(in)        :: lgt_block(:, :)
    !> heavy data array - block data
    real(kind=rk), intent(inout)        :: hvy_block(:, :, :, :, :)
    !> heavy data array - neighbor data
    integer(kind=ik), intent(in)        :: hvy_neighbor(:,:)
    !> list of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_active(:)
    !> number of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_n

    ! status of nodes check: if true: stops program
    logical, intent(inout)              :: stop_status
    ! stage0: correct blocks that are on the same level, but have a different history. one is on Jmax from
    ! before, one has just gotten to Jmax via interpolation. In those cases, the former block has the status +11
    ! which indicates that its redundant nodes must overwrite the ones on the other block (which has been interpolated)
    logical, intent(in):: stage0, force_averaging

    ! MPI parameter
    integer(kind=ik)                    :: rank
    ! number of processes
    integer(kind=ik)                    :: number_procs

    ! loop variables
    integer(kind=ik)                    :: N, k, dF, neighborhood, invert_neighborhood, neighbor_num, level_diff, l

    ! id integers
    integer(kind=ik)                    :: lgt_id, neighbor_light_id, neighbor_rank, hvy_id

    ! type of data bounds
    ! exclude_redundant, include_redundant, only_redundant
    integer(kind=ik)                    :: data_bounds_type
    integer(kind=ik), dimension(2,3)    :: data_bounds, data_bounds2

    ! data buffer size
    integer(kind=ik)                    :: buffer_size, buffer_position

    ! grid parameter
    integer(kind=ik)                    :: Bs, g, stage_start
    ! number of datafields
    integer(kind=ik)                    :: NdF

    ! type of data writing
    character(len=25)                   :: data_writing_type

    ! communications matrix (only 1 line)
    ! note: todo: check performance without allocation?
    ! todo: remove dummy com matrix, needed for old MPI subroutines
    integer(kind=ik), allocatable     :: com_matrix(:), dummy_matrix(:,:)

    ! synch stage loop variables
    integer(kind=ik) :: synch_stage, stages
    ! synch status
    ! synch == .true. : active block sends data to neighboring block
    ! neighbor_synch == .true. : neighbor block send data to active block
    logical    :: synch, neighbor_synch, test2

!---------------------------------------------------------------------------------------------
! interfaces

 !---------------------------------------------------------------------------------------------
! variables initialization

    if (.not. ghost_nodes_module_ready) then
        call init_ghost_nodes( params )
    endif

    ! hack to use subroutine as redundant nodes test and for ghost nodes synchronization
    if (stop_status) then
        ! synchronization
        ! exclude_redundant, include_redundant, only_redundant
        data_bounds_type = include_redundant
        ! 'average', 'simple', 'staging', 'compare'
        data_writing_type = 'staging'

        if ( force_averaging ) then
          data_writing_type='average'
        endif

    else
        ! nodes test
        ! exclude_redundant, include_redundant, only_redundant
        data_bounds_type = only_redundant
        ! 'average', 'simple', 'staging', 'compare'
        data_writing_type = 'compare'
        ! reset status
        stop_status = .false.

    end if

    ! grid parameter
    Bs    = params%number_block_nodes
    g     = params%number_ghost_nodes
    ! number of datafields
    NdF   = params%number_data_fields

    ! set number of blocks
    N = params%number_blocks

    ! set MPI parameter
    rank = params%rank
    number_procs = params%number_procs

    ! set loop number for 2D/3D case
    neighbor_num = size(hvy_neighbor, 2)

    ! 2D only!
    allocate( com_matrix(number_procs), dummy_matrix(number_procs, number_procs) )

    ! reset ghost nodes for all blocks - for debugging
    ! todo: use reseting subroutine from MPI module
    ! if ( (params%test_ghost_nodes_synch) .and. (data_bounds_type /= only_redundant) ) then
    !     !-- x-direction
    !     hvy_block(1:g, :, :, :, : )           = 9.0e9_rk
    !     hvy_block(Bs+g+1:Bs+2*g, :, :, :, : ) = 9.0e9_rk
    !     !-- y-direction
    !     hvy_block(:, 1:g, :, :, : )           = 9.0e9_rk
    !     hvy_block(:, Bs+g+1:Bs+2*g, :, :, : ) = 9.0e9_rk
    !     !-- z-direction
    !     if ( params%threeD_case ) then
    !         hvy_block(:, :, 1:g, :, : )           = 9.0e9_rk
    !         hvy_block(:, :, Bs+g+1:Bs+2*g, :, : ) = 9.0e9_rk
    !     end if
    ! end if

    ! reset com matrix
    com_matrix = 0
    dummy_matrix = 0

    ! reseting all ghost nodes to zero
    if ( (data_writing_type == 'average') .and. (data_bounds_type /= only_redundant) ) then
        do k = 1, hvy_n
            !-- x-direction
            hvy_block(1:g, :, :, :, hvy_active(k) )               = 0.0_rk
            hvy_block(Bs+g+1:Bs+2*g, :, :, :, hvy_active(k) )     = 0.0_rk
            !-- y-direction
            hvy_block(:, 1:g, :, :, hvy_active(k) )               = 0.0_rk
            hvy_block(:, Bs+g+1:Bs+2*g, :, :, hvy_active(k) )     = 0.0_rk
            !-- z-direction
            if ( params%threeD_case ) then
                hvy_block(:, :, 1:g, :, hvy_active(k) )           = 0.0_rk
                hvy_block(:, :, Bs+g+1:Bs+2*g, :, hvy_active(k) ) = 0.0_rk
            end if
        end do
    end if

    stage_start = 1
    stages = 1

    ! set number of synch stages
    if ( data_writing_type == 'staging' ) then
        ! all four stages
        stages = 4
        ! if zeroth stage is specified, we do only that, and not all the other stages
        if (stage0) then
            stage_start=0
            stages = 0
        endif
    end if

!---------------------------------------------------------------------------------------------
! main body


    ! loop over all synch stages
    do synch_stage = stage_start, stages

        ! in the staging type the ghost nodes bounds depend on the stage as well
        if (data_writing_type=="staging") then
            if (synch_stage==3)  then
                data_bounds_type = exclude_redundant

            elseif (synch_stage == 0) then
                ! stage0: correct blocks that are on the same level, but have a different history. one is on Jmax from
                ! before, one has just gotten to Jmax via interpolation. In those cases, the former block has the status +11
                ! which indicates that its redundant nodes must overwrite the ones on the other block (which has been interpolated)
                data_bounds_type = only_redundant

            else
                data_bounds_type = include_redundant
            endif
        endif

        ! reset integer send buffer position
        int_pos = 2
        ! reset first in send buffer position
        int_send_buffer( 1, : ) = 0
        int_send_buffer( 2, : ) = -99

        ! loop over active heavy data
        if (data_writing_type=="average") then
            do k = 1, hvy_n

                ! reset synch array
                ! alles auf null, knoten im block auf 1
                ! jeder später gespeicherte knoten erhöht wert um 1
                ! am ende der routine wird der wert aus dem synch array ggf. für die durchschnittsberechnung benutzt
                ! synch array hat die maximale anzahl von blöcken pro prozess alloziiert, so dass die heavy id unverändert
                ! benutzt werden kann
                ! ghost nodes layer auf 1 setzen, wenn nur die redundanten Knoten bearbeitet werden
                if (data_bounds_type == only_redundant) then
                    hvy_synch(:, :, :, hvy_active(k)) = 1
                else
                    hvy_synch(:, :, :, hvy_active(k)) = 0
                end if
                ! alles knoten im block werden auf 1 gesetzt

                ! todo: ist erstmal einfacher als nur die redundaten zu setzen, aber unnötig
                ! so gibt es aber nach der synch keine nullen mehr, kann ggf. als synch test verwendet werden?
                if ( params%threeD_case ) then
                    hvy_synch( g+1:Bs+g, g+1:Bs+g, g+1:Bs+g, hvy_active(k)) = 1
                else
                    hvy_synch( g+1:Bs+g, g+1:Bs+g, 1, hvy_active(k)) = 1
                end if

            end do
        end if

        ! loop over active heavy data
        do k = 1, hvy_n
            ! loop over all neighbors
            do neighborhood = 1, neighbor_num
                ! neighbor exists
                if ( hvy_neighbor( hvy_active(k), neighborhood ) /= -1 ) then

                    ! 0. ids bestimmen
                    ! neighbor light data id
                    neighbor_light_id = hvy_neighbor( hvy_active(k), neighborhood )
                    ! calculate neighbor rank
                    call lgt_id_to_proc_rank( neighbor_rank, neighbor_light_id, N )
                    ! calculate light id
                    call hvy_id_to_lgt_id( lgt_id, hvy_active(k), rank, N )
                    ! neighbor heavy id
                    call lgt_id_to_hvy_id( hvy_id, neighbor_light_id, neighbor_rank, N )
                    ! calculate the difference between block levels
                    ! define leveldiff: sender - receiver, so +1 means sender on higher level
                    ! sender is active block (me)
                    level_diff = lgt_block( lgt_id, params%max_treelevel+1 ) - lgt_block( neighbor_light_id, params%max_treelevel+1 )

                    ! 1. ich (aktiver block) ist der sender für seinen nachbarn
                    ! lese daten und sortiere diese in bufferform
                    ! wird auch für interne nachbarn gemacht, um gleiche routine für intern/extern zu verwenden
                    ! um diue lesbarkeit zu erhöhen werden zunächst die datengrenzen bestimmt
                    ! diese dann benutzt um die daten zu lesen
                    ! 2D/3D wird bei der datengrenzbestimmung unterschieden, so dass die tatsächliche leseroutine stark vereinfacht ist
                    ! da die interpolation bei leveldiff -1 erst bei der leseroutine stattfindet, werden als datengrenzen die für die interpolation noitwendigen bereiche angegeben
                    ! auch für restriction ist der datengrenzenbereich größer, da dann auch hier später erst die restriction stattfindet
                    call calc_data_bounds( params, data_bounds, neighborhood, level_diff, data_bounds_type, 'sender' )

                    ! vor dem schreiben der daten muss ggf interpoliert werden
                    ! hier werden die datengrenzen ebenfalls angepasst
                    ! interpolierte daten stehen in einem extra array
                    ! dessen größe richtet sich nach dem größten möglichen interpolationsgebiet: (Bs+2*g)^3
                    ! auch die vergröberten daten werden in den interpolationbuffer geschrieben und die datengrenzen angepasst
                    if ( level_diff == 0 ) then
                        ! lese nun mit den datengrenzen die daten selbst
                        ! die gelesenen daten werden als buffervektor umsortiert
                        ! so können diese danach entweder in den buffer geschrieben werden oder an die schreiberoutine weitergegeben werden
                        ! in die lese routine werden nur die relevanten Daten (data bounds) übergeben
                        call GhostLayer2Line( params, line_buffer, buffer_size, &
                        hvy_block( data_bounds(1,1):data_bounds(2,1), data_bounds(1,2):data_bounds(2,2), data_bounds(1,3):data_bounds(2,3), :, hvy_active(k)) )
                    else
                        ! interpoliere daten
                        call restrict_predict_data( params, res_pre_data, data_bounds, neighborhood, level_diff, data_bounds_type, hvy_block, hvy_active(k), data_bounds2 )
                        ! lese daten, verwende interpolierte daten
                        call GhostLayer2Line( params, line_buffer, buffer_size, res_pre_data( data_bounds2(1,1):data_bounds2(2,1), &
                                                                                            data_bounds2(1,2):data_bounds2(2,2), &
                                                                                            data_bounds2(1,3):data_bounds2(2,3), &
                                                                                            :) )

                    end if

                    ! daten werden jetzt entweder in den speicher geschrieben -> schreiberoutine
                    ! oder in den send buffer geschrieben
                    ! schreiberoutine erhält die date grenzen
                    ! diese werden vorher durch erneuten calc data bounds aufruf berechnet
                    ! achtung: die nachbarschaftsbeziehung wird hier wie eine interner Kopieren ausgewertet
                    ! invertierung der nachbarschaftsbeziehung findet beim füllen des sendbuffer statt
                    if ( (rank==neighbor_rank).and.(data_writing_type=='simple') ) then
                        ! internal neighbor and direct writing method: copy the ghost nodes as soon as possible, without passing
                        ! via the buffers first.
                        ! data bounds
                        call calc_data_bounds( params, data_bounds, neighborhood, level_diff, data_bounds_type, 'receiver' )
                        ! simply write data. No care
                        call Line2GhostLayer( params, line_buffer, data_bounds, hvy_block, hvy_id )

                    else
                        !call abort(1212,'debug, why more than one prossess ?')
                        ! synch status for staging method
                        synch = .true.
                        if (data_writing_type == 'staging') then
                            call set_synch_status( synch_stage, synch, neighbor_synch, level_diff, hvy_neighbor, &
                            hvy_active(k), neighborhood, lgt_block(lgt_id,params%max_treelevel+2), lgt_block(neighbor_light_id,params%max_treelevel+2)  )
                        end if
                        ! first: fill com matrix, count number of communication to neighboring process, needed for int buffer length
                        com_matrix(neighbor_rank+1) = com_matrix(neighbor_rank+1) + 1

                        if (synch) then
                            ! active block send data to his neighbor block
                            ! fill int/real buffer
                            call AppendLineToBuffer( int_send_buffer, real_send_buffer, buffer_size, neighbor_rank, line_buffer, int_pos(neighbor_rank+1), hvy_id, neighborhood, level_diff )
                        else
                            ! neighbor block send data to active block
                            ! write -1 to int_send buffer, placeholder
                            int_send_buffer( int_pos(neighbor_rank+1) : int_pos(neighbor_rank+1)+4  , neighbor_rank+1 ) = -1
                            ! increase int buffer position
                            int_pos(neighbor_rank+1) = int_pos(neighbor_rank+1) + 5
                        end if

                    end if

                end if
            end do
        end do

        ! pretend that no communication with myself takes place, in order to skip the
        ! MPI transfer in the following routine. NOTE: you can also skip this step and just have isend_irecv_data_2
        ! transfer the data, in which case you should skip the copy part directly after isend_irecv_data_2
        com_matrix(rank+1) = 0

        !***********************************************************************
        ! transfer part (send/recv)
        !***********************************************************************
        ! send/receive data
        ! note: todo, remove dummy subroutine
        ! note: new dummy subroutine sets receive buffer position accordingly to process rank
        ! note: todo: use more than non-blocking send/receive
        call isend_irecv_data_2( params, int_send_buffer, real_send_buffer, int_receive_buffer, real_receive_buffer, com_matrix  )

        ! fill receive buffer for internal neighbors for averaging writing type
        if ( (data_writing_type == 'average') .or. (data_writing_type == 'compare') .or. (data_writing_type == 'staging') ) then
            ! fill receive buffer
            int_receive_buffer( 1:int_pos(rank+1)  , rank+1 ) = int_send_buffer( 1:int_pos(rank+1)  , rank+1 )
            real_receive_buffer( 1:int_receive_buffer(1,rank+1), rank+1 ) = real_send_buffer( 1:int_receive_buffer(1,rank+1), rank+1 )
            ! change com matrix, need to sort in buffers in next step
            com_matrix(rank+1) = 1
        end if

        !***********************************************************************
        ! Unpack received data in the ghost node layers
        !***********************************************************************
        ! Daten einsortieren
        ! für simple, average, compare: einfach die buffer einsortieren, Reihenfolge ist egal
        ! staging: erneuter loop über alle blöcke und nachbarschaften, wenn daten notwendig, werden diese in den buffern gesucht
        if ( data_writing_type /= 'staging' ) then
            ! sortiere den real buffer ein
            ! loop over all procs
            do k = 1, number_procs
                if ( com_matrix(k) /= 0 ) then
                    ! neighboring proc
                    ! first element in int buffer is real buffer size
                    l = 2
                    ! -99 marks end of data
                    do while ( int_receive_buffer(l, k) /= -99 )

                        ! hvy id
                        hvy_id = int_receive_buffer(l, k)
                        ! neighborhood
                        neighborhood = int_receive_buffer(l+1, k)
                        ! level diff
                        level_diff = int_receive_buffer(l+2, k)
                        ! buffer position
                        buffer_position = int_receive_buffer(l+3, k)
                        ! buffer size
                        buffer_size = int_receive_buffer(l+4, k)

                        ! data buffer
                        line_buffer(1:buffer_size) = real_receive_buffer( buffer_position : buffer_position-1 + buffer_size, k )

                        ! data bounds
                        call calc_data_bounds( params, data_bounds, neighborhood, level_diff, data_bounds_type, 'receiver' )
                        ! write data, hängt vom jeweiligen Fall ab
                        ! average: schreibe daten, merke Anzahl der geschriebenen Daten, Durchschnitt nach dem Einsortieren des receive buffers berechnet
                        ! simple: schreibe ghost nodes einfach in den speicher (zum Testen?!)
                        ! staging: wende staging konzept an
                        ! compare: vergleiche werte mit vorhandenen werten (nur für redundante knoten sinnvoll, als check routine)
                        select case(data_writing_type)
                            case('simple')
                                ! simply write data
                                call Line2GhostLayer( params, line_buffer, data_bounds, hvy_block, hvy_id )

                            case('average')
                                ! add data
                                call add_hvy_data( params, line_buffer, data_bounds, hvy_block, hvy_synch, hvy_id )

                            case('compare')
                                ! compare data
                                call hvy_id_to_lgt_id( lgt_id, hvy_id, rank, N )
                                call compare_hvy_data( params, line_buffer, data_bounds, hvy_block, hvy_id, stop_status, level_diff, &
                                 lgt_block(lgt_id, params%max_treelevel+2), treecode2int( lgt_block(lgt_id, 1:params%max_treelevel) ) )

                        end select

                        ! increase buffer postion marker
                        l = l + 5

                    end do
                end if
            end do

            ! last averaging step
            if ( data_writing_type == 'average' ) then
                ! loop over active heavy data
                do k = 1, hvy_n
                    do dF = 1, NdF

                        ! calculate average for all nodes, todo: proof performance?
                        hvy_block(:, :, :, dF, hvy_active(k)) = hvy_block(:, :, :, dF, hvy_active(k)) / real( hvy_synch(:, :, :, hvy_active(k)) , kind=rk)

                    end do
                end do
            end if

        else
            ! staging type
            ! loop over active heavy data
            do k = 1, hvy_n
                ! loop over all neighbors
                do neighborhood = 1, neighbor_num
                    ! neighbor exists
                    if ( hvy_neighbor( hvy_active(k), neighborhood ) /= -1 ) then

                        ! invert neighborhood, needed for in buffer searching, because sender proc has invert neighborhood relation
                        invert_neighborhood = inverse_neighbor(neighborhood, dim)

                        ! 0. ids bestimmen
                        ! neighbor light data id
                        neighbor_light_id = hvy_neighbor( hvy_active(k), neighborhood )
                        ! calculate neighbor rank
                        call lgt_id_to_proc_rank( neighbor_rank, neighbor_light_id, N )
                        ! calculate light id
                        call hvy_id_to_lgt_id( lgt_id, hvy_active(k), rank, N )
                        ! calculate the difference between block levels
                        ! define leveldiff: sender - receiver, so +1 means sender on higher level
                        ! sender is active block (me)
                        level_diff = lgt_block( lgt_id, params%max_treelevel+1 ) - lgt_block( neighbor_light_id, params%max_treelevel+1 )

                        ! set synch status
                        call set_synch_status( synch_stage, synch, neighbor_synch, level_diff, hvy_neighbor, &
                        hvy_active(k), neighborhood, lgt_block(lgt_id, params%max_treelevel+2), lgt_block(neighbor_light_id,params%max_treelevel+2) )
                        ! synch == .true. bedeutet, dass der aktive block seinem nachbarn daten gibt
                        ! hier sind wir aber auf der seite des empfängers, das bedeutet, neighbor_synch muss ausgewertet werden

                        if (neighbor_synch) then

                            ! search buffers for synchronized data
                            ! first element in int buffer is real buffer size
                            l = 2

                            ! -99 marks end of data
                            test2 = .false.
                            do while ( int_receive_buffer(l, neighbor_rank+1) /= -99 )

                                ! proof heavy id and neighborhood id
                                if (  (int_receive_buffer( l,   neighbor_rank+1 ) == hvy_active(k) ) &
                                .and. (int_receive_buffer( l+1, neighbor_rank+1 ) == invert_neighborhood) ) then

                                    ! set parameter
                                    ! level diff, read from buffer because calculated level_diff is not sender-receiver
                                    level_diff = int_receive_buffer(l+2, neighbor_rank+1)
                                    ! buffer position
                                    buffer_position = int_receive_buffer(l+3, neighbor_rank+1)
                                    ! buffer size
                                    buffer_size = int_receive_buffer(l+4, neighbor_rank+1)

                                    ! data buffer
                                    line_buffer(1:buffer_size) = real_receive_buffer( buffer_position : buffer_position-1 + buffer_size, neighbor_rank+1 )

                                    ! data bounds
                                    call calc_data_bounds( params, data_bounds, invert_neighborhood, level_diff, data_bounds_type, 'receiver' )

                                    ! write data
                                    call Line2GhostLayer( params, line_buffer(1:buffer_size), data_bounds, hvy_block, hvy_active(k) )

                                    ! done, exit the while loop?
                                    test2=.true.
                                    exit
                                end if

                                ! increase buffer postion marker
                                l = l + 5

                            end do
                            if (test2 .eqv. .false.) call abort(777771,"not found")

                        end if

                    end if
                end do
            end do

        end if

    end do ! loop over stages

    if ( data_writing_type=='compare' ) then
        test2 = stop_status
        call MPI_Allreduce(test2, stop_status, 1,MPI_LOGICAL, MPI_LOR, WABBIT_COMM, k )
    endif

    ! clean up
    deallocate( com_matrix, dummy_matrix )

end subroutine check_redundant_nodes



subroutine synchronize_ghosts_generic_sequence( params, lgt_block, hvy_block, hvy_neighbor, hvy_active, hvy_n )

    implicit none

    !> user defined parameter structure
    type (type_params), intent(in)      :: params
    !> light data array
    integer(kind=ik), intent(in)        :: lgt_block(:, :)
    !> heavy data array - block data
    real(kind=rk), intent(inout)        :: hvy_block(:, :, :, :, :)
    !> heavy data array - neighbor data
    integer(kind=ik), intent(in)        :: hvy_neighbor(:,:)
    !> list of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_active(:)
    !> number of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_n

    ! MPI parameter
    integer(kind=ik)   :: myrank, mpisize, irank
    ! grid parameter
    integer(kind=ik)   :: Bs, g, NdF
    ! loop variables
    integer(kind=ik)   :: N, k, dF, neighborhood, invert_neighborhood, level_diff, l, levelsToSortIn
    ! merged information of level diff and an indicator that we have a historic finer sender
    integer(kind=ik)   :: level_diff_indicator
    ! id integers
    integer(kind=ik)   :: neighbor_lgt_id, neighbor_rank, hvy_id_receiver
    integer(kind=ik)   :: sender_hvy_id, sender_lgt_id
    ! data buffer size
    integer(kind=ik)  :: buffer_size, buffer_position,data_bounds(1:2,1:3)

    integer(kind=ik)  :: hvyId_temp   ! just for a  consistency check
    integer(kind=ik)  :: entrySortInRound , currentSortInRound

    integer :: bounds_type
    logical :: senderHistoricFine, recieverHistoricFine, receiverIsCoarser
    logical :: receiverIsOnSameLevel, lgtIdSenderIsHigher

    !---------------------------------------------------------------------------------------------
    ! variables initialization
    if (.not. ghost_nodes_module_ready) then
        call init_ghost_nodes( params )
    endif

    Bs    = params%number_block_nodes
    g     = params%number_ghost_nodes
    NdF   = params%number_data_fields
    N = params%number_blocks
    myrank = params%rank
    mpisize = params%number_procs
    communication_counter(:) = 0

    !---------------------------------------------------------------------------------------------
    ! main body

    ! reset integer send buffer position
    int_pos = 2       ! TODO JR why 2? , the first filed contains the size of the XXX
    ! reset first in send buffer position
    int_send_buffer( 1, : ) = 0
    int_send_buffer( 2, : ) = -99


    ! debug check if hvy_active is sorted
    if (hvy_n>1) then
        hvyId_temp =  hvy_active(1)
        do k = 2, hvy_n
            if  (hvyId_temp> hvy_active(k))  then
                call abort(1212,' hvy_active is not sorted as assumed. Panic!')
            end if
            hvyId_temp = hvy_active(k)
        end do
    end if

    ! loop over active heavy data
    do k = 1, hvy_n
        ! calculate light id
        sender_hvy_id = hvy_active(k)
        call hvy_id_to_lgt_id( sender_lgt_id, hvy_active(k), myrank, N )

        ! loop over all neighbors
        do neighborhood = 1, size(hvy_neighbor, 2)
            ! neighbor exists
            if ( hvy_neighbor( hvy_active(k), neighborhood ) /= -1 ) then

                !  ----------------------------  determin the core ids and properties of neighbor  ------------------------------
                ! TODO: check if info available when searching neighbor and store it in hvy_neighbor
                ! neighbor light data id
                neighbor_lgt_id = hvy_neighbor( hvy_active(k), neighborhood )
                ! calculate neighbor rank
                call lgt_id_to_proc_rank( neighbor_rank, neighbor_lgt_id, N )
                ! neighbor heavy id
                call lgt_id_to_hvy_id( hvy_id_receiver, neighbor_lgt_id, neighbor_rank, N )
                ! define level difference: sender - receiver, so +1 means sender on higher level
                level_diff = lgt_block( sender_lgt_id, params%max_treelevel+1 ) - lgt_block( neighbor_lgt_id, params%max_treelevel+1 )

                !  ----------------------------  here decide which values are taken for redundant nodes --------------------------------

                ! here is the core of the ghost point rules
                ! primary criterion: (very fine/historic fine) wins over (fine) wins over (same) wins over (coars)
                ! secondary criterion: the higer light id wins

                ! comment: the same dominance rules within the ghos nodes are realized by the sequence of filling in the values,
                ! first coarse then same then finer, always in the sequence of the hvy id the redundant nodes within the ghost nodes and maybe in the
                ! redundant nodes are written several time, the one folling the above rules should win

                ! the criteria
                senderHistoricFine      = ( lgt_block( sender_lgt_id, params%max_treelevel+2)==11)
                recieverHistoricFine    = ( lgt_block(neighbor_lgt_id, params%max_treelevel+2)==11)
                receiverIsCoarser       = ( level_diff<0_ik )
                receiverIsOnSameLevel   = ( level_diff==0_ik )
                lgtIdSenderIsHigher     = ( neighbor_lgt_id < sender_lgt_id  )

                bounds_type = exclude_redundant  ! default value, may be changed below
                ! in what round in the extraction process will this neighborhood be unpacked?
                entrySortInRound = level_diff + 2  ! now has values 1,2,3 ; is overwritten with 4 if sender is historic fine

                ! here we decide who dominates. would be simple without the historic fine
                if (senderHistoricFine) then
                    ! the 4th unpack round is the last one, so setting 4 ensures that historic fine always wins
                    entrySortInRound = 4
                    if (recieverHistoricFine) then
                        if (lgtIdSenderIsHigher)  then
                            ! both are historic fine, the redundant nodes are overwritten using secondary criterion
                            bounds_type = include_redundant
                        end if
                    else
                        ! receiver not historic fine, so sender always sends redundant nodes, no further
                        ! checks on refinement level are required
                        bounds_type = include_redundant
                    end if

                else  ! sender NOT historic fine,

                    ! what about the neighbor/receiver, historic fine?
                    if ( .not. recieverHistoricFine) then
                        ! neither one is historic fine, so just do the basic rules

                        ! first rule, overwrite cosarser ghost nodes
                        if (receiverIsCoarser)  then ! receiver is coarser
                            bounds_type = include_redundant
                        end if

                        ! secondary rule: on same level decide using light id
                        if (receiverIsOnSameLevel.and.lgtIdSenderIsHigher) then
                            bounds_type = include_redundant
                        end if
                    end if
                end if  ! else  senderHistoricFine

                !----------------------------  pack describing data and node values to send ---------------------------
                ! pack multipe information; just to keep old structure, but I save also send data size
                ! more information could be included boundary type, .. but might not be worth the effort
                if ( myrank == neighbor_rank ) then
                    level_diff_indicator =  4096*sender_hvy_id + 256*bounds_type + 16*(level_diff+1) + entrySortInRound

                    ! the packing has limitations: if the numbers are too large, it might fail, so check here. TODO
                    if (sender_hvy_id.ne.( level_diff_indicator/4096 ) )  call abort(1212,' wrong sender_hvy_id !')

                    call AppendLineToBuffer( int_send_buffer, real_send_buffer, 1_ik, neighbor_rank, line_buffer, int_pos(neighbor_rank+1), &
                    hvy_id_receiver, neighborhood, level_diff_indicator )
                else
                    ! first: fill com matrix, count number of communication to neighboring process, needed for int buffer length
                    communication_counter(neighbor_rank+1) = communication_counter(neighbor_rank+1) + 1

                    level_diff_indicator = 256*bounds_type + 16*(level_diff+1) + entrySortInRound


                    ! 1. ich (aktiver block) ist der sender für seinen nachbarn
                    ! lese daten und sortiere diese in bufferform
                    ! wird auch für interne nachbarn gemacht, um gleiche routine für intern/extern zu verwenden
                    ! um diue lesbarkeit zu erhöhen werden zunächst die datengrenzen bestimmt
                    ! diese dann benutzt um die daten zu lesen
                    ! 2D/3D wird bei der datengrenzbestimmung unterschieden, so dass die tatsächliche leseroutine stark vereinfacht ist
                    ! da die interpolation bei leveldiff -1 erst bei der leseroutine stattfindet, werden als datengrenzen die für die interpolation noitwendigen bereiche angegeben
                    ! auch für restriction ist der datengrenzenbereich größer, da dann auch hier später erst die restriction stattfindet
! call calc_data_bounds( params, data_bounds, neighborhood, level_diff, bounds_type, 'sender' )

                    ! vor dem schreiben der daten muss ggf interpoliert werden
                    ! hier werden die datengrenzen ebenfalls angepasst
                    ! interpolierte daten stehen in einem extra array
                    ! dessen größe richtet sich nach dem größten möglichen interpolationsgebiet: (Bs+2*g)^3
                    ! auch die vergröberten daten werden in den interpolationbuffer geschrieben und die datengrenzen angepasst
                    if ( level_diff == 0 ) then
                        ! lese nun mit den datengrenzen die daten selbst
                        ! die gelesenen daten werden als buffervektor umsortiert
                        ! so können diese danach entweder in den buffer geschrieben werden oder an die schreiberoutine weitergegeben werden
                        ! in die lese routine werden nur die relevanten Daten (data bounds) übergeben
! call GhostLayer2Line( params, line_buffer, buffer_size, &
! hvy_block( data_bounds(1,1):data_bounds(2,1), data_bounds(1,2):data_bounds(2,2), data_bounds(1,3):data_bounds(2,3), :, hvy_active(k)) )

                        call GhostLayer2Line( params, line_buffer, buffer_size, &
                        hvy_block( ijkghosts(1,1, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,1, neighborhood, level_diff, dim, bounds_type, 1), &
                                   ijkghosts(1,2, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,2, neighborhood, level_diff, dim, bounds_type, 1), &
                                   ijkghosts(1,3, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,3, neighborhood, level_diff, dim, bounds_type, 1), &
                                   :, hvy_active(k)) )
                    else
                        ! interpoliere daten
                        call restrict_predict_data( params, res_pre_data, ijkghosts(:,:, neighborhood, level_diff, dim, bounds_type, 1), &
                        neighborhood, level_diff, bounds_type, hvy_block, hvy_active(k), data_bounds )
                        ! lese daten, verwende interpolierte daten
                        call GhostLayer2Line( params, line_buffer, buffer_size, &
                        res_pre_data( data_bounds(1,1):data_bounds(2,1), &
                                      data_bounds(1,2):data_bounds(2,2), &
                                      data_bounds(1,3):data_bounds(2,3), &
                        :) )
                        ! call GhostLayer2Line( params, line_buffer, buffer_size, &
                        ! res_pre_data( ijkghosts(1,1, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,1, neighborhood, level_diff, dim, bounds_type, 1), &
                        !               ijkghosts(1,2, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,2, neighborhood, level_diff, dim, bounds_type, 1), &
                        !               ijkghosts(1,3, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,3, neighborhood, level_diff, dim, bounds_type, 1), &
                        ! :) )
                    end if

                    ! daten werden jetzt entweder in den speicher geschrieben -> schreiberoutine
                    ! oder in den send buffer geschrieben
                    ! schreiberoutine erhält die date grenzen
                    ! diese werden vorher durch erneuten calc data bounds aufruf berechnet
                    ! achtung: die nachbarschaftsbeziehung wird hier wie eine interner Kopieren ausgewertet
                    ! invertierung der nachbarschaftsbeziehung findet beim füllen des sendbuffer statt

                    ! active block send data to his neighbor block
                    ! fill int/real buffer
                    call AppendLineToBuffer( int_send_buffer, real_send_buffer, buffer_size, neighbor_rank, line_buffer, int_pos(neighbor_rank+1), &
                    hvy_id_receiver, neighborhood, level_diff_indicator )
                end if ! (myrank==neighbor_rank)

            end if ! neighbor exists
        end do ! loop over all possible  neighbors
    end do ! loop over all heavy active

    !***********************************************************************
    ! transfer part (send/recv)
    !***********************************************************************
    ! send/receive data
    ! note: todo, remove dummy subroutine
    ! note: new dummy subroutine sets receive buffer position accordingly to process myrank
    ! note: todo: use more than non-blocking send/receive
    call isend_irecv_data_2( params, int_send_buffer, real_send_buffer, int_receive_buffer, real_receive_buffer, communication_counter  )

    !***********************************************************************
    ! Unpack received data in the ghost node layers
    !***********************************************************************
    ! sort data in, ordering is important to keep dominance rules within ghost nodes.
    ! the redundand nodes owend by two blocks only should be taken care by bounds_type (include_redundant. exclude_redundant )
    do currentSortInRound = 1, 4 ! coarse, same, fine, historic fine
        do irank = 1, mpisize  ! by this the light id's are sorted in by corrctly if the data contain it in the right sequence per proc
            if (irank == myrank+1) then
                !>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
                ! process-internal ghost points (direct copy)
                !>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
                l = 2  ! first field is size of data
                do while ( int_send_buffer(l, irank) /= -99 )
                    ! unpack the description of the next data chunk
                    ! required info:  sender_hvy_id, hvy_id_receiver, neighborhood, level_diff, bounds_type, entrySortInRound
                    hvy_id_receiver = int_send_buffer(l, irank)
                    neighborhood = int_send_buffer(l+1, irank)

                    ! unpack & evaluate level_diff_indicator (contains multiple information, unpack it)
                    level_diff_indicator = int_send_buffer(l+2, irank)
                    entrySortInRound = modulo( level_diff_indicator, 16 )

                    ! check if this entry is processed in this round, otherwise cycle to next
                    if (entrySortInRound /= currentSortInRound) then
                        l = l + 5  ! to read the next entry
                        cycle      ! go on to next entry
                    end if

                    level_diff      = modulo( level_diff_indicator/16  , 16 ) - 1_ik
                    bounds_type     = modulo( level_diff_indicator/256 , 16 )
                    sender_hvy_id   =       ( level_diff_indicator/4096 )

                    ! data bounda for sender and receiver
!                    call calc_data_bounds( params, data_bounds, neighborhood, level_diff, bounds_type, 'sender' )
!                    call calc_data_bounds( params, data_bounds_receiver, neighborhood, level_diff, bounds_type , 'receiver' )

                    if ( level_diff == 0 ) then
                        ! simply copy from sender block to receiver block (NOTE both are on the same MPIRANK)
                        hvy_block( ijkghosts(1,1, neighborhood, level_diff, dim, bounds_type, 2):ijkghosts(2,1, neighborhood, level_diff, dim, bounds_type, 2), &
                                   ijkghosts(1,2, neighborhood, level_diff, dim, bounds_type, 2):ijkghosts(2,2, neighborhood, level_diff, dim, bounds_type, 2), &
                                   ijkghosts(1,3, neighborhood, level_diff, dim, bounds_type, 2):ijkghosts(2,3, neighborhood, level_diff, dim, bounds_type, 2), :, hvy_id_receiver ) = &
                        hvy_block( ijkghosts(1,1, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,1, neighborhood, level_diff, dim, bounds_type, 1), &
                                   ijkghosts(1,2, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,2, neighborhood, level_diff, dim, bounds_type, 1), &
                                   ijkghosts(1,3, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,3, neighborhood, level_diff, dim, bounds_type, 1), :, sender_hvy_id)

                    else  ! interpolation or restriction before inserting
                        call restrict_predict_data( params, res_pre_data, ijkghosts(1:2,1:3, neighborhood, level_diff, dim, bounds_type, 1), neighborhood, level_diff, &
                        bounds_type, hvy_block, sender_hvy_id, data_bounds )

                        ! copy interpolated / restricted data to ghost nodes layer
                        hvy_block( ijkghosts(1,1, neighborhood, level_diff, dim, bounds_type, 2):ijkghosts(2,1, neighborhood, level_diff, dim, bounds_type, 2), &
                                   ijkghosts(1,2, neighborhood, level_diff, dim, bounds_type, 2):ijkghosts(2,2, neighborhood, level_diff, dim, bounds_type, 2), &
                                   ijkghosts(1,3, neighborhood, level_diff, dim, bounds_type, 2):ijkghosts(2,3, neighborhood, level_diff, dim, bounds_type, 2), :, hvy_id_receiver ) = &
                        res_pre_data( data_bounds(1,1):data_bounds(2,1), &
                                      data_bounds(1,2):data_bounds(2,2), &
                                      data_bounds(1,3):data_bounds(2,3), :)
                        ! ! copy interpolated / restricted data to ghost nodes layer
                        ! hvy_block( ijkghosts(1,1, neighborhood, level_diff, dim, bounds_type, 2):ijkghosts(2,1, neighborhood, level_diff, dim, bounds_type, 2), &
                        !            ijkghosts(1,2, neighborhood, level_diff, dim, bounds_type, 2):ijkghosts(2,2, neighborhood, level_diff, dim, bounds_type, 2), &
                        !            ijkghosts(1,3, neighborhood, level_diff, dim, bounds_type, 2):ijkghosts(2,3, neighborhood, level_diff, dim, bounds_type, 2), :, hvy_id_receiver ) = &
                        ! res_pre_data( ijkghosts(1,1, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,1, neighborhood, level_diff, dim, bounds_type, 1), &
                        !               ijkghosts(1,2, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,2, neighborhood, level_diff, dim, bounds_type, 1), &
                        !               ijkghosts(1,3, neighborhood, level_diff, dim, bounds_type, 1):ijkghosts(2,3, neighborhood, level_diff, dim, bounds_type, 1), :)
                    end if

                    ! increase buffer postion marker
                    l = l + 5
                end do
            else
                !>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
                ! process-external ghost points (copy from buffer)
                !>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
                ! did I recv something from this rank?
                if ( (communication_counter(irank) /= 0) ) then
                    l = 2  ! first field is size of data
                    do while ( int_receive_buffer(l, irank) /= -99 )
                        ! unpack the description of the next data chunk
                        hvy_id_receiver = int_receive_buffer(l, irank)
                        neighborhood = int_receive_buffer(l+1, irank)

                        ! unpack & evaluate level_diff_indicator (contains multiple information, unpack it)
                        level_diff_indicator = int_receive_buffer(l+2, irank)
                        entrySortInRound = modulo( level_diff_indicator, 16 )

                        ! check if this entry is processed in this round, otherwise cycle to next
                        if (entrySortInRound /= currentSortInRound ) then
                            l = l + 5  ! to read the next entry
                            cycle      ! go on to next entry
                        end if

                        level_diff      = modulo( level_diff_indicator/16 , 16 ) - 1_ik
                        bounds_type     = modulo( level_diff_indicator/256, 16 )
                        ! ---------------------------

                        buffer_position = int_receive_buffer(l+3, irank)
                        buffer_size = int_receive_buffer(l+4, irank)

                        ! fill the data buffer to sort it in
                        line_buffer(1:buffer_size) = real_receive_buffer( buffer_position : buffer_position-1 + buffer_size, irank )

                        ! data bounds
!                        call calc_data_bounds( params, data_bounds, neighborhood, level_diff,  bounds_type, 'receiver' )

                        ! simply write data
                        call Line2GhostLayer( params, line_buffer, ijkghosts(:,:, neighborhood, level_diff, dim, bounds_type, 2), hvy_block, hvy_id_receiver )

                        ! increase buffer postion marker
                        l = l + 5
                    end do
                end if

            end if  ! process-internal or external ghost points
        end do ! mpisize
    end do ! currentSortInRound
end subroutine synchronize_ghosts_generic_sequence

!############################################################################################################

subroutine GhostLayer2Line( params, line_buffer, buffer_counter, hvy_data )
    implicit none

    !> user defined parameter structure
    type (type_params), intent(in)   :: params
    !> data buffer
    real(kind=rk), intent(out)       :: line_buffer(:)
    ! buffer size
    integer(kind=ik), intent(out)    :: buffer_counter
    !> heavy block data, all data fields
    real(kind=rk), intent(in)        :: hvy_data(:, :, :, :)

    ! loop variable
    integer(kind=ik) :: i, j, k, dF
    ! reset buffer size
    buffer_counter = 0

    ! loop over all data fields
    do dF = 1, params%number_data_fields
        do k = 1, size(hvy_data, 3) ! third dimension, note: for 2D cases k is always 1
            do j = 1, size(hvy_data, 2)
                do i = 1, size(hvy_data, 1)
                    ! increase buffer size
                    buffer_counter = buffer_counter + 1
                    ! write data buffer
                    line_buffer(buffer_counter)   = hvy_data( i, j, k, dF )
                end do
            end do
        end do
    end do

end subroutine GhostLayer2Line

!############################################################################################################

subroutine Line2GhostLayer( params, line_buffer, data_bounds, hvy_block, hvy_id )
    implicit none

    !> user defined parameter structure
    type (type_params), intent(in)  :: params
    !> data buffer
    real(kind=rk), intent(in)       :: line_buffer(:)
    !> data_bounds
    integer(kind=ik), intent(in)    :: data_bounds(2,3)
    !> heavy data array - block data
    real(kind=rk), intent(inout)    :: hvy_block(:, :, :, :, :)
    !> hvy id
    integer(kind=ik), intent(in)    :: hvy_id

    ! loop variable
    integer(kind=ik) :: i, j, k, dF, buffer_i

    buffer_i = 1
    ! loop over all data fields
    do dF = 1, params%number_data_fields
        do k = data_bounds(1,3), data_bounds(2,3) ! third dimension, note: for 2D cases k is always 1
            do j = data_bounds(1,2), data_bounds(2,2)
                do i = data_bounds(1,1), data_bounds(2,1)
                    ! write data buffer
                    hvy_block( i, j, k, dF, hvy_id ) = line_buffer( buffer_i )
                    buffer_i = buffer_i + 1
                end do
            end do
        end do
    end do

end subroutine Line2GhostLayer

!############################################################################################################

subroutine add_hvy_data( params, line_buffer, data_bounds, hvy_block, hvy_synch, hvy_id )

!---------------------------------------------------------------------------------------------
! modules

!---------------------------------------------------------------------------------------------
! variables

    implicit none

    !> user defined parameter structure
    type (type_params), intent(in)                  :: params
    !> data buffer
    real(kind=rk), intent(in)                 :: line_buffer(:)
    !> data_bounds
    integer(kind=ik), intent(in)                 :: data_bounds(2,3)
    !> heavy data array - block data
    real(kind=rk), intent(inout)                       :: hvy_block(:, :, :, :, :)
    !> heavy synch array
    integer(kind=1), intent(inout)      :: hvy_synch(:, :, :, :)
    !> hvy id
    integer(kind=ik), intent(in)                    :: hvy_id

    ! loop variable
    integer(kind=ik)                                :: i, j, k, dF, buffer_i

!---------------------------------------------------------------------------------------------
! interfaces

!---------------------------------------------------------------------------------------------
! variables initialization

    buffer_i = 1

!---------------------------------------------------------------------------------------------
! main body

    ! loop over all data fields
    do dF = 1, params%number_data_fields
        ! first dimension
        do i = data_bounds(1,1), data_bounds(2,1)
            ! second dimension
            do j = data_bounds(1,2), data_bounds(2,2)
                ! third dimension, note: for 2D cases kN is always 1
                do k = data_bounds(1,3), data_bounds(2,3)

                    ! write data buffer
                    hvy_block( i, j, k, dF, hvy_id ) = hvy_block( i, j, k, dF, hvy_id ) + line_buffer( buffer_i )

                    ! count synchronized data
                    ! note: only for first datafield
                    if (dF==1) hvy_synch( i, j, k, hvy_id ) = hvy_synch( i, j, k, hvy_id ) + 1_1

                    ! increase buffer counter
                    buffer_i = buffer_i + 1

                end do
            end do
        end do
    end do

end subroutine add_hvy_data

!############################################################################################################

subroutine compare_hvy_data( params, line_buffer, data_bounds, hvy_block, hvy_id, stop_status, level_diff, my_ref, tc )

!---------------------------------------------------------------------------------------------
! modules

!---------------------------------------------------------------------------------------------
! variables

    implicit none

    !> user defined parameter structure
    type (type_params), intent(in)                  :: params
    !> data buffer
    real(kind=rk), intent(in)                 :: line_buffer(:)
    !> data_bounds
    integer(kind=ik), intent(in)                 :: data_bounds(2,3)
    !> heavy data array - block data
    real(kind=rk), intent(inout)                       :: hvy_block(:, :, :, :, :)
    !> hvy id
    integer(kind=ik), intent(in)                    :: hvy_id, level_diff, my_ref
    ! status of nodes check: if true: stops program
    logical, intent(inout)              :: stop_status
    integer(kind=tsize)::tc

    ! loop variable
    integer(kind=ik)                                :: i, j, k, dF, buffer_i, oddeven, bs, g

    ! error threshold
    real(kind=rk)                                   :: eps

    ! error norm
    real(kind=rk)       :: error_norm
    real(kind=rk), allocatable :: tmp(:,:), tmp2(:,:)

    Bs = params%number_block_nodes
    g = params%number_ghost_nodes

    allocate( tmp(1:Bs+2*g,1:Bs+2*g), tmp2(1:Bs+2*g,1:Bs+2*g))
    tmp = 0.0_rk
    tmp2 = 0.0_rk

!---------------------------------------------------------------------------------------------
! variables initialization
    buffer_i = 1

    ! set error threshold
    eps = 1e-14_rk

    ! reset error norm
    error_norm = 0.0_rk

    ! the first index of the redundant points is (g+1, g+1, g+1)
    ! so if g is even, then we must compare the odd indices i,j,k on the lines
    ! of the redundant points.
    ! if g is odd, then we must compare the even ones
    ! Further note that BS is odd (always), so as odd+even=odd and odd+odd=even
    ! we can simply study the parity of g
    oddeven = mod(params%number_ghost_nodes,2)

!---------------------------------------------------------------------------------------------
! main body
    ! loop over all data fields
    do dF = 1, params%number_data_fields
        ! first dimension
        do i = data_bounds(1,1), data_bounds(2,1)
            ! second dimension
            do j = data_bounds(1,2), data_bounds(2,2)
                ! third dimension, note: for 2D cases k is always 1
                do k = data_bounds(1,3), data_bounds(2,3)

                    if (level_diff/=-1) then
                        ! on the same level, the comparison just takes all points, no odd/even downsampling required.
                        error_norm = max(error_norm, abs(hvy_block( i, j, k, dF, hvy_id ) - line_buffer( buffer_i )))
                        tmp(i,j) = abs(hvy_block( i, j, k, dF, hvy_id ) - line_buffer( buffer_i ))
                        tmp2(i,j) = 7.7_rk
                    else
                        ! if the level diff is -1, I compare with interpolated (upsampled) data. that means every EVEN
                        ! point is the result of interpolation, and not truely redundant.
                        ! Note this routine ALWAYS just compares the redundant nodes, so it will mostly be called
                        ! with a line of points (i.e. one dimension is length one)
                        !
                        ! This routine has been tested:
                        !   - old method (working version): no error found (okay)
                        !   - old method, non_uniform_mesh_correction=0; in params file -> plenty of errors (okay)
                        !   - old method, sync stage 4 deactivated: finds all occurances of "3finer blocks on corner problem" (okay)
                        !   - new method, averaging, no error found (makes sense: okay)
                        if (oddeven==0) then
                            ! even number of ghost nodes
                            if (((data_bounds(2,1)- data_bounds(1,1) == 0).and.(mod(j,2)/=0)) .or. ((data_bounds(2,2)-data_bounds(1,2) == 0).and.(mod(i,2)/=0))) then
                                error_norm = max(error_norm, abs(hvy_block( i, j, k, dF, hvy_id ) - line_buffer( buffer_i )))
                                tmp(i,j) = abs(hvy_block( i, j, k, dF, hvy_id ) - line_buffer( buffer_i ))
                                tmp2(i,j) = 7.7_rk
                            endif
                        else
                            ! odd number of ghost nodes
                            if (((data_bounds(2,1)- data_bounds(1,1) == 0).and.(mod(j,2)==0)) .or. ((data_bounds(2,2)-data_bounds(1,2) == 0).and.(mod(i,2)==0))) then
                                error_norm = max(error_norm, abs(hvy_block( i, j, k, dF, hvy_id ) - line_buffer( buffer_i )))
                                tmp(i,j) = abs(hvy_block( i, j, k, dF, hvy_id ) - line_buffer( buffer_i ))
                                tmp2(i,j) = 7.7_rk
                            endif
                        endif
                    endif
                    buffer_i = buffer_i + 1

                end do
            end do
        end do
    end do

    if (error_norm > eps)  then
        write(*,'("ERROR: difference in redundant nodes ",es12.4," level_diff=",i2, " hvy_id=",i8, " rank=",i5 )') &
        error_norm, level_diff, hvy_id, params%rank
        write(*,*) "refinement status", my_ref, "tc=", tc
        ! stop program
        stop_status = .true.

        ! write(*,*) "---"
        ! do i =  Bs+2*g, 1, -1
        !     write(*,'(70(es8.1,1x))') hvy_block(:,i,1,1,hvy_id)
        ! enddo
        ! write(*,*) "---"
        ! do j = Bs+2*g, 1, -1
        !     do i = 1, Bs+2*g
        !         if (tmp(i,j)==0.0_rk) then
        !             write(*,'(" null    ")', advance="no")
        !         else
        !             write(*,'((es8.1,1x))', advance="no") tmp(i,j)
        !         endif
        !     enddo
        !     write(*,*) " "
        ! enddo
        ! write(*,*) "---"

        ! mark block by putting a dot in the middle. this way, we can identify all
        ! blocks that have problems. If we set the entire block to 100, then subsequent
        ! synchronizations fail because of that. If we set just a point in the middle, it
        ! is far away from the boundary and thus does not affect other sync steps.
        hvy_block( size(hvy_block,1)/2, size(hvy_block,2)/2, :, :, hvy_id ) = 100.0_rk
    end if

    deallocate(tmp, tmp2)
end subroutine compare_hvy_data

!############################################################################################################

subroutine isend_irecv_data_2( params, int_send_buffer, real_send_buffer, int_receive_buffer, real_receive_buffer, com_matrix )

!---------------------------------------------------------------------------------------------
! modules

!---------------------------------------------------------------------------------------------
! variables

    implicit none

    !> user defined parameter structure
    type (type_params), intent(in)      :: params

    !> send/receive buffer, integer and real
    integer(kind=ik), intent(in)        :: int_send_buffer(:,:)
    integer(kind=ik), intent(out)       :: int_receive_buffer(:,:)

    real(kind=rk), intent(in)           :: real_send_buffer(:,:)
    real(kind=rk), intent(out)          :: real_receive_buffer(:,:)

    !> communications matrix: neighboring proc rank
    !> com matrix pos: position in send buffer
    integer(kind=ik), intent(in)        :: com_matrix(:)

    ! process rank
    integer(kind=ik)                    :: rank
    ! MPI error variable
    integer(kind=ik)                    :: ierr
    ! number of processes
    integer(kind=ik)                    :: number_procs
    ! MPI status
    !integer                             :: status(MPI_status_size)

    ! MPI message tag
    integer(kind=ik)                    :: tag
    ! MPI request
    integer(kind=ik)                    :: send_request(size(com_matrix,1)), recv_request(size(com_matrix,1))

    ! column number of send buffer, column number of receive buffer, real data buffer length
    integer(kind=ik)                    :: real_pos, int_length

    ! loop variable
    integer(kind=ik)                    :: k, i

!---------------------------------------------------------------------------------------------
! interfaces

!---------------------------------------------------------------------------------------------
! variables initialization

    ! set MPI parameters
    rank            = params%rank
    number_procs    = params%number_procs

    ! set message tag
    tag = 0

!---------------------------------------------------------------------------------------------
! main body

    ! ----------------------------------------------------------------------------------------
    ! first: integer data

    ! reset communication counter
    i = 0

    ! reset request arrays
    recv_request = MPI_REQUEST_NULL
    send_request = MPI_REQUEST_NULL

    ! loop over com matrix
    do k = 1, number_procs

        ! communication between proc rank and proc k-1
        if ( com_matrix(k) > 0 ) then

            ! legth of integer buffer
            int_length = 5*com_matrix(k) + 3

            ! increase communication counter
            i = i + 1

            ! tag
            tag = rank+1+k

            ! receive data
            call MPI_Irecv( int_receive_buffer(1, k), int_length, MPI_INTEGER4, k-1, tag, WABBIT_COMM, recv_request(i), ierr)

            ! send data
            call MPI_Isend( int_send_buffer(1, k), int_length, MPI_INTEGER4, k-1, tag, WABBIT_COMM, send_request(i), ierr)

        end if

    end do

    !> \todo Please check if waiting twice is really necessary
    ! synchronize non-blocking communications
    ! note: single status variable do not work with all compilers, so use MPI_STATUSES_IGNORE instead
    if (i>0) then
        call MPI_Waitall( i, send_request(1:i), MPI_STATUSES_IGNORE, ierr) !status, ierr)
        call MPI_Waitall( i, recv_request(1:i), MPI_STATUSES_IGNORE, ierr) !status, ierr)
    end if

    ! ----------------------------------------------------------------------------------------
    ! second: real data

    ! reset communication couter
    i = 0

    ! reset request arrays
    recv_request = MPI_REQUEST_NULL
    send_request = MPI_REQUEST_NULL

    ! loop over corresponding com matrix line
    do k = 1, number_procs

        ! communication between proc rank and proc k-1
        if ( com_matrix(k) > 0 ) then

            ! increase communication counter
            i = i + 1

            tag = number_procs*10*(rank+1+k)

            ! real buffer length
            real_pos = int_receive_buffer(1, k)

            ! receive data
            call MPI_Irecv( real_receive_buffer(1, k), real_pos, MPI_REAL8, k-1, tag, WABBIT_COMM, recv_request(i), ierr)

            ! real buffer length
            real_pos = int_send_buffer(1, k)

            ! send data
            call MPI_Isend( real_send_buffer(1, k), real_pos, MPI_REAL8, k-1, tag, WABBIT_COMM, send_request(i), ierr)

        end if

    end do

    ! synchronize non-blocking communications
    if (i>0) then
        call MPI_Waitall( i, send_request(1:i), MPI_STATUSES_IGNORE, ierr) !status, ierr)
        call MPI_Waitall( i, recv_request(1:i), MPI_STATUSES_IGNORE, ierr) !status, ierr)
    end if

end subroutine isend_irecv_data_2

!############################################################################################################

subroutine set_synch_status( synch_stage, synch, neighbor_synch, level_diff, hvy_neighbor, &
    hvy_id, neighborhood, my_ref_status, neighbor_ref_status )

!---------------------------------------------------------------------------------------------
! modules

!---------------------------------------------------------------------------------------------
! variables

    implicit none

    ! synch stage
    integer(kind=ik), intent(in)        :: synch_stage

    ! synch status
    logical, intent(inout)    :: synch, neighbor_synch

    ! level difference
    integer(kind=ik), intent(in)        :: level_diff, my_ref_status, neighbor_ref_status

    ! heavy data array - neighbor data
    integer(kind=ik), intent(in)        :: hvy_neighbor(:,:)

    ! list of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_id

    !> neighborhood relation, id from dirs
    integer(kind=ik), intent(in)                    :: neighborhood

!---------------------------------------------------------------------------------------------
! interfaces

!---------------------------------------------------------------------------------------------
! variables initialization

!---------------------------------------------------------------------------------------------
! main body

    ! set synch stage
    ! stage 1: level +1
    ! stage 2: level 0
    ! stage 3: level -1
    ! stage 4: special
    synch = .false.
    neighbor_synch = .false.

    ! this is the zeroth stage. it corrects blocks that are on the same level, but have a different history. one is on Jmax from
    ! before, one has just gotten to Jmax via interpolation. In those cases, the former block has the status +11
    ! which indicates that its redundant nodes must overwrite the ones on the other block (which has been interpolated)
    if ((synch_stage==0) .and. (level_diff==0)) then
        if ((my_ref_status==11) .and. (neighbor_ref_status/=11)) then
            ! if a block has the +11 status, it must send data to the neighbor, if that is not +11
            synch = .true.
        elseif ((my_ref_status/=11) .and. (neighbor_ref_status==11)) then
            ! if a block is not +11 and its neighbor is, then unpack data
            neighbor_synch = .true.
        endif
    endif


    ! stage 1
    if ( (synch_stage == 1) .and. (level_diff == 1) ) then
        ! block send data
        synch = .true.
    elseif ( (synch_stage == 1) .and. (level_diff == -1) ) then
        ! neighbor send data
        neighbor_synch = .true.
    end if

    ! stage 2
    if ( (synch_stage == 2) .and. (level_diff == 0) ) then
        ! block send data
        synch = .true.
        ! neighbor send data
        neighbor_synch = .true.
    end if

    ! stage 3
    if ( (synch_stage == 3) .and. (level_diff == -1) ) then
        ! block send data
        synch = .true.
    elseif ( (synch_stage == 3) .and. (level_diff == 1) ) then
        ! neighbor send data
        neighbor_synch = .true.
    end if

    ! stage 4
    if ( (synch_stage == 4) .and. (level_diff == 0) ) then
        ! neighborhood NE
        if ( neighborhood == 5 ) then
            if ( (hvy_neighbor( hvy_id, 9) /= -1) .or. (hvy_neighbor( hvy_id, 13) /= -1) ) then
                synch = .true.
                neighbor_synch = .true.
            end if
        end if
        ! neighborhood NW
        if ( neighborhood == 6 ) then
            if ( (hvy_neighbor( hvy_id, 10) /= -1) .or. (hvy_neighbor( hvy_id, 15) /= -1) ) then
                synch = .true.
                neighbor_synch = .true.
            end if
        end if
        ! neighborhood SE
        if ( neighborhood == 7 ) then
            if ( (hvy_neighbor( hvy_id, 11) /= -1) .or. (hvy_neighbor( hvy_id, 14) /= -1) ) then
                synch = .true.
                neighbor_synch = .true.
            end if
        end if
        ! neighborhood SW
        if ( neighborhood == 8 ) then
            if ( (hvy_neighbor( hvy_id, 12) /= -1) .or. (hvy_neighbor( hvy_id, 16) /= -1) ) then
                synch = .true.
                neighbor_synch = .true.
            end if
        end if
    end if

end subroutine set_synch_status

!############################################################################################################

subroutine AppendLineToBuffer( int_send_buffer, real_send_buffer, buffer_size, neighbor_rank, line_buffer, int_pos, &
    hvy_id, neighborhood, level_diff )

    implicit none

    !> send buffers, integer and real
    integer(kind=ik), intent(inout)        :: int_send_buffer(:,:)
    real(kind=rk), intent(inout)           :: real_send_buffer(:,:)
    ! data buffer size
    integer(kind=ik), intent(in)           :: buffer_size
    ! id integer
    integer(kind=ik), intent(in)           :: neighbor_rank
    ! restricted/predicted data buffer
    real(kind=rk), intent(in)              :: line_buffer(:)
    ! integer buffer position
    integer(kind=ik), intent(inout)        :: int_pos
    ! data buffer intergers, receiver heavy id, neighborhood id, level difference
    integer(kind=ik), intent(in)           :: hvy_id, neighborhood, level_diff

    ! buffer position
    integer(kind=ik)                       :: buffer_position

    ! fill real buffer
    ! position in real buffer is stored in int buffer
    buffer_position = int_send_buffer(1  , neighbor_rank+1 ) + 1

    ! real data
    real_send_buffer( buffer_position : buffer_position-1 + buffer_size, neighbor_rank+1 ) = line_buffer(1:buffer_size)

    ! fill int buffer
    ! sum size of single buffers on first element
    int_send_buffer(1  , neighbor_rank+1 ) = int_send_buffer(1  , neighbor_rank+1 ) + buffer_size

    ! save: neighbor id, neighborhood, level difference, buffer size
    int_send_buffer( int_pos,   neighbor_rank+1 ) = hvy_id
    int_send_buffer( int_pos+1, neighbor_rank+1 ) = neighborhood
    int_send_buffer( int_pos+2, neighbor_rank+1 ) = level_diff
    int_send_buffer( int_pos+3, neighbor_rank+1 ) = buffer_position
    int_send_buffer( int_pos+4, neighbor_rank+1 ) = buffer_size
    ! mark end of buffer with -99, will be overwritten by next element if it is nt the last one
    int_send_buffer( int_pos+5, neighbor_rank+1 ) = -99

    int_pos = int_pos +5
end subroutine AppendLineToBuffer

!############################################################################################################
subroutine write_real5(data_block,hvy_active, hvy_n, fileName )

    !> list of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_active(:)
   !> number of active blocks (heavy data)
    integer(kind=ik), intent(in)        :: hvy_n

    real(kind=rk), intent(in)       :: data_block(:, :, :, :, :)
    character(len=128), intent(in)  :: fileName
    integer                         :: i,j,k,l,m

    open(unit=11, file= fileName, form='unformatted', status='replace',access='stream')

    !write(*,*) size(data_block,1), size(data_block,2), size(data_block,3), size(data_block,4), hvy_n

    write(11) size(data_block,1), size(data_block,2), size(data_block,3), size(data_block,4), hvy_n
!   write(*,*) 'max', maxval(data_block)
!   write(*,*) 'min',     minval(data_block)
   !write(*,*) 'real5'
   do m = 1, hvy_n
    !write(*,*) 'max val ', m,hvy_active(m) , maxval(data_block(:,:,:,:, hvy_active(m)) )
        ! loop sequence not very quick, but i prefere this sequence
        do i =1,size(data_block,1)
            do j =1,size(data_block,2)
                do k =1,size(data_block,3)
                    do l =1,size(data_block,4)

                            write(11) i,j,k,l, m , data_block(i, j, k, l, hvy_active(m) )
                         !write(*,*) i,j,k,l, m , data_block(i, j, k, l, hvy_active(m) )
                    end do
                end do
            end do
        end do

    end do

    close(11)
end subroutine
!############################################################################################################
