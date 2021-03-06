module SoundPressureLevel

using Distributed
using Dates
using Random
using Soundcard
using Libaudio
using DeviceUnderTest



struct Instrument
    calibrator::String
    dbspl::Float64
    dba::Float64
    lastcal::Date
    mic::String
    preamp::String
    gainpreamp::Float64
    soundcard::String 
end


function inst2str(x::Instrument)
    s = string(x)
    s = replace(s, "SoundPressureLevel.Instrument("=>"")
    s = replace(s, "\"" => "")
    s = replace(s, ")"=>"")
    s = replace(s, ':'=>'-')
    s = replace(s, ", "=>"_")
end


function addlatest(mm::Matrix, t, fs, root, id=Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFX"))
    r = Soundcard.record(round(Int, t * fs), mm, fs)
    p = replace(string(now()), [':','.']=>'-')
    Libaudio.wavwrite(joinpath(root, p * "+" * inst2str(id) * ".wav"), r, Int(fs), 32)
    return r
end



function getlatest(root, id=Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFX"))
    loc = ""
    tspan = Vector{DateTime}([now(), now()])
    archive = [(DateTime(String(split(basename(i),"+")[1]), DateFormat("y-m-dTH-M-S-s")), i) for i in Libaudio.list(root, ".wav")]
    sort!(archive, by=x->x[1], rev=true)
    for i in archive
        if String(split(basename(i[2]),"+")[2]) == inst2str(id) * ".wav"
            tspan[1] = i[1]
            loc = i[2]
            break
        end
    end
    loc, diff(tspan)[1]
end



"""
- 'fs': is the canonical sample rate in [8000, 16000, 44100, 48000, 96000, 192000]
        so to convert from precise to canonical use [findmin(abs.(av.-fs))[2]]
"""
function recording(f, y, ms::Matrix, mm::Matrix, fs, synchronous=true)
    if synchronous
        r = Soundcard.playrecord(y, ms, mm, fs)
    else
        out = "_splout.wav"
        Libaudio.wavwrite(out, DeviceUnderTest.mixer(y, ms), Int(fs), 32)
        try
            f[:init]()
            f[:readyplay](out)
            done = remotecall(f[:play], workers()[1])
            r = Soundcard.record(size(y,1), mm, fs)
            fetch(done)
        finally
            # rm(out, force=true)
        end
    end
    return convert(Matrix{Float64},r)
end















"""
    getdbaspread() set tartget level roughly to 'dbasetting' and measures the new level several times to find out the spreadout.
    if 'dbasetting' is NaN then the spreadout is measured at its 'gaininit' level
"""
function getdbaspread(
    f,
    symbol::Vector, 
    rep::Int, 
    gaininit, 
    ms::Matrix, 
    mm::Matrix, 
    fs, 
    dbasetting,
    nspread::Int, 
    root,
    piston = Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    piezo = Instrument("42AB",114,114,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    synchronous = true,
    tcs = 3.0,
    td = 2.0,
    maxdayadd = 1,
    maxdaycal = 180,
    barocorrection = 0.0)
    
    @assert nprocs() > 1
    @assert size(ms, 1) == 1
    @assert size(mm, 2) == 1
    @assert now() - DateTime(piston.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))
    @assert now() - DateTime(piezo.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))

    pstnl, pstnd = getlatest(root, piston)
    pezol, pezod = getlatest(root, piezo)

    rootlog = joinpath(Libaudio.folder(), Libaudio.logfile())
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::vector): use latest calibration files:")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::vector): $pstnl")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::vector): $pezol")

    if maxdayadd > 0
        pstnd ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::vector): calibration is too old")
        pezod ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::vector): calibration is too old")
    end
    wf = Libaudio.WindowFrame(fs,16384,16384÷4)
    pstn, sr = Libaudio.wavread(pstnl, Float64)
    pezo, sr = Libaudio.wavread(pezol, Float64)

    m = length(symbol)
    n = round(Int, td*fs)
    x = zeros(m+n,1)
    x[1:m,1] = symbol * 10^(gaininit/20)
    y = recording(f, [zeros(round(Int,tcs*fs),1); repeat(x,rep,1)], ms, mm, fs, synchronous)  
    
    nspread = max(1, nspread)
    val = zeros(Bool, 3+nspread)
    val[1], pstnspl = Libaudio.spl(pstn[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piston.dbspl+barocorrection)
    val[2], pezospl = Libaudio.spl(pezo[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piezo.dbspl)
    val[3], pezodba = Libaudio.spl(pezo[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::vector): calibration deviation $(abs(pstnspl[1]-pezospl[1])) dB")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::vector): levels = $(pstnspl[1]) dB(SPL), $(pezospl[1]) dB(SPL), $(pezodba[1]) dB(A)")

    gainadj = isnan(dbasetting) ? gaininit : (gaininit+(dbasetting-pezodba[1]))
    x[1:m,1] = symbol * 10^(gainadj/20)
    
    dbaspread = zeros(eltype(pezodba), nspread)
    for i = 1:nspread
        y = recording(f, [zeros(round(Int,tcs*fs),1); repeat(x,rep,1)], ms, mm, fs, synchronous)
        val[3+i], dbaspreads = Libaudio.spl(pezo[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")
        dbaspread[i] = dbaspreads[1]
    end
    return (all(val), gainadj, dbaspread)
end

function getdbaspread(
    f,
    source::Matrix, 
    gaininit, 
    ms::Matrix, 
    mm::Matrix, 
    fs, 
    dbasetting, 
    nspread::Int, 
    root,
    piston = Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    piezo = Instrument("42AB",114,114,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    synchronous = true,
    syncatten = -12,
    tcs = 3.0,
    td = 2.0,
    maxdayadd = 1,
    maxdaycal = 180,
    barocorrection = 0.0,
    fm = fs)
    
    @assert nprocs() > 1
    @assert size(mm,2) == 1
    @assert now() - DateTime(piston.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))
    @assert now() - DateTime(piezo.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))

    pstnl, pstnd = getlatest(root, piston)
    pezol, pezod = getlatest(root, piezo)

    rootlog = joinpath(Libaudio.folder(), Libaudio.logfile())
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::matrix): use latest calibration files:") 
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::matrix): $pstnl") 
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::matrix): $pezol") 

    if maxdayadd > 0
        pstnd ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::matrix): calibration is too old") 
        pezod ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::matrix): calibration is too old") 
    end
    wf = Libaudio.WindowFrame(fs,16384,16384÷4)
    pstn, sr = Libaudio.wavread(pstnl, Float64)
    pezo, sr = Libaudio.wavread(pezol, Float64)

    nspread = max(1, nspread)
    val = zeros(Bool, 4+2nspread)

    rate = synchronous ? fs : fm
    s = Libaudio.symbol_expsinesweep(800, 2000, 0.5, rate)
    x = Libaudio.encode_syncsymbol(tcs, s, td, 10^(gaininit/20) * source, rate, 1, syncatten)
    y = recording(f, x, ms, mm, fs, synchronous)
    val[1], symloc = Libaudio.decode_syncsymbol(y, s, td, size(source,1)/rate, fs)
    bl = symloc[1]
    br = symloc[1] + round(Int,size(source,1)/rate*fs) - 1

    val[2], pstnspl = Libaudio.spl(pstn[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piston.dbspl+barocorrection)
    val[3], pezospl = Libaudio.spl(pezo[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piezo.dbspl)
    val[4], pezodba = Libaudio.spl(pezo[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::matrix): calibration deviation $(abs(pstnspl[1]-pezospl[1])) dB") 
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdbaspread(::matrix): levels = $(pstnspl[1]) dB(SPL), $(pezospl[1]) dB(SPL), $(pezodba[1]) dB(A)")

    gainadj = isnan(dbasetting) ? gaininit : (gaininit+(dbasetting-pezodba[1]))
    x = Libaudio.encode_syncsymbol(tcs, s, td, 10^(gainadj/20) * source, rate, 1, syncatten)

    dbaspread = zeros(eltype(pezodba), nspread)
    for i = 1:nspread
        y = recording(f, x, ms, mm, fs, synchronous) 
        val[4+2i-1], symloc = Libaudio.decode_syncsymbol(y, s, td, size(source,1)/rate, fs)
        bl = symloc[1]
        br = symloc[1] + round(Int,size(source,1)/rate*fs) - 1    
        val[4+2i], dbaspreads = Libaudio.spl(pezo[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")
        dbaspread[i] = dbaspreads[1]
    end
    
    return (all(val), gainadj, dbaspread)
end








function getdba(
    f,
    symbol::Vector, 
    rep::Int, 
    gaininit, 
    ms::Matrix, 
    mm::Matrix, 
    fs, 
    root,
    piston = Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    piezo = Instrument("42AB",114,114,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    synchronous = true,
    tcs = 3.0,
    td = 2.0,
    maxdayadd = 1,
    maxdaycal = 180,
    barocorrection = 0.0)
    
    @assert nprocs() > 1
    @assert size(ms, 1) == 1
    @assert size(mm, 2) == 1
    @assert now() - DateTime(piston.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))
    @assert now() - DateTime(piezo.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))

    pstnl, pstnd = getlatest(root, piston)
    pezol, pezod = getlatest(root, piezo)

    rootlog = joinpath(Libaudio.folder(), Libaudio.logfile())
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdba(::vector): use latest calibration files:")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdba(::vector): $pstnl")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdba(::vector): $pezol")

    if maxdayadd > 0
        pstnd ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.getdba(::vector): calibration is too old")
        pezod ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.getdba(::vector): calibration is too old")
    end
    wf = Libaudio.WindowFrame(fs,16384,16384÷4)
    pstn, sr = Libaudio.wavread(pstnl, Float64)
    pezo, sr = Libaudio.wavread(pezol, Float64)

    m = length(symbol)
    n = round(Int, td*fs)
    x = zeros(m+n,1)

    x[1:m,1] = symbol * 10^(gaininit/20)
    y = recording(f, [zeros(round(Int,tcs*fs),1); repeat(x,rep,1)], ms, mm, fs, synchronous)  
    
    val = Bool[0,0,0]
    val[1], pstnspl = Libaudio.spl(pstn[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piston.dbspl+barocorrection)
    val[2], pezospl = Libaudio.spl(pezo[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piezo.dbspl)
    val[3], dbainit = Libaudio.spl(pezo[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdba(::vector): calibration deviation $(abs(pstnspl[1]-pezospl[1])) dB")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdba(::vector): levels = $(pstnspl[1]) dB(SPL), $(pezospl[1]) dB(SPL), $(dbainit[1]) dB(A)")

    return (all(val), dbainit[1])
end

function setdba(
    f,
    symbol::Vector, 
    rep::Int, 
    gaininit, 
    dbainit,
    dbasetting,
    dbatol,
    ms::Matrix, 
    mm::Matrix, 
    fs, 
    root,
    piston = Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    piezo = Instrument("42AB",114,114,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    synchronous = true,
    tcs = 3.0,
    td = 2.0,
    maxdayadd = 1,
    maxdaycal = 180,
    barocorrection = 0.0)

    @assert nprocs() > 1
    @assert size(ms, 1) == 1
    @assert size(mm, 2) == 1
    @assert now() - DateTime(piston.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))
    @assert now() - DateTime(piezo.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))

    
    pezol, pezod = getlatest(root, piezo)
    maxdayadd > 0 && pezod ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(joinpath(Libaudio.folder(), Libaudio.logfile()), :light_red, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): calibration is too old")
    
    wf = Libaudio.WindowFrame(fs,16384,16384÷4)
    pezo, sr = Libaudio.wavread(pezol, Float64)

    m = length(symbol)
    n = round(Int, td*fs)
    x = zeros(m+n,1)

    gainadj = gaininit
    dbaadj = dbainit

    while true
        gainadj = gainadj+(dbasetting-dbaadj)
        x[1:m,1] = symbol * 10^(gainadj/20)
        y = recording(f, [zeros(round(Int,tcs*fs),1); repeat(x,rep,1)], ms, mm, fs, synchronous)  
        val, dbanow = Libaudio.spl(pezo[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")
        dbaadj = dbanow[1]

        if val && (dbasetting + dbatol ≥ dbaadj ≥ dbasetting - dbatol)
            Libaudio.printl(joinpath(Libaudio.folder(), Libaudio.logfile()), :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): tolerance satisfied")
            break
        else
            Libaudio.printl(joinpath(Libaudio.folder(), Libaudio.logfile()), :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): deviation = $(abs(dbaadj-dbasetting)), retry...")
        end
    end
    return (gainadj, dbaadj)
end










function getdba(
    f,
    source::Matrix, 
    gaininit, 
    ms::Matrix, 
    mm::Matrix, 
    fs, 
    root,
    piston = Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    piezo = Instrument("42AB",114,114,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    synchronous = true,
    syncatten = -12,
    tcs = 3.0,
    td = 2.0,
    maxdayadd = 1,
    maxdaycal = 180,
    barocorrection = 0.0,
    fm = fs)
    
    @assert nprocs() > 1
    @assert size(mm,2) == 1
    @assert now() - DateTime(piston.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))
    @assert now() - DateTime(piezo.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))

    pstnl, pstnd = getlatest(root, piston)
    pezol, pezod = getlatest(root, piezo)

    rootlog = joinpath(Libaudio.folder(), Libaudio.logfile())
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdba(::matrix): use latest calibration files:") 
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdba(::matrix): $pstnl") 
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdba(::matrix): $pezol") 

    if maxdayadd > 0
        pstnd ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.getdba(::matrix): calibration is too old") 
        pezod ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.getdba(::matrix): calibration is too old") 
    end
    wf = Libaudio.WindowFrame(fs,16384,16384÷4)
    pstn, sr = Libaudio.wavread(pstnl, Float64)
    pezo, sr = Libaudio.wavread(pezol, Float64)

    val = Bool[0,0,0,0]

    rate = synchronous ? fs : fm
    s = Libaudio.symbol_expsinesweep(800, 2000, 0.5, rate)
    x = Libaudio.encode_syncsymbol(tcs, s, td, 10^(gaininit/20) * source, rate, 1, syncatten)
    y = recording(f, x, ms, mm, fs, synchronous)
    val[1], symloc = Libaudio.decode_syncsymbol(y, s, td, size(source,1)/rate, fs)
    bl = symloc[1]
    br = symloc[1] + round(Int,size(source,1)/rate*fs) - 1

    val[2], pstnspl = Libaudio.spl(pstn[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piston.dbspl+barocorrection)
    val[3], pezospl = Libaudio.spl(pezo[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piezo.dbspl)
    val[4], dbainit = Libaudio.spl(pezo[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")

    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdba(::matrix): calibration deviation $(abs(pstnspl[1]-pezospl[1])) dB") 
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.getdba(::vector): levels = $(pstnspl[1]) dB(SPL), $(pezospl[1]) dB(SPL), $(dbainit[1]) dB(A)")

    return (all(val), dbainit[1])
end

function setdba(
    f,
    source::Matrix, 
    gaininit, 
    dbainit,
    dbasetting,
    dbatol,
    ms::Matrix, 
    mm::Matrix, 
    fs, 
    root,
    piston = Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    piezo = Instrument("42AB",114,114,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    synchronous = true,
    syncatten = -12,
    tcs = 3.0,
    td = 2.0,
    maxdayadd = 1,
    maxdaycal = 180,
    barocorrection = 0.0,
    fm = fs)
    
    @assert nprocs() > 1
    @assert size(mm,2) == 1
    @assert now() - DateTime(piston.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))
    @assert now() - DateTime(piezo.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))


    pezol, pezod = getlatest(root, piezo)
    maxdayadd > 0 && pezod ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(joinpath(Libaudio.folder(), Libaudio.logfile()), :light_red, Libaudio.nows() * " | SoundPressureLevel.setdba(::matrix): calibration is too old") 
    
    wf = Libaudio.WindowFrame(fs,16384,16384÷4)
    pezo, sr = Libaudio.wavread(pezol, Float64)
    rate = synchronous ? fs : fm


    gainadj = gaininit
    dbaadj = dbainit

    while true
        gainadj = gainadj+(dbasetting-dbaadj)
        s = Libaudio.symbol_expsinesweep(800, 2000, 0.5, rate)
        x = Libaudio.encode_syncsymbol(tcs, s, td, 10^(gainadj/20) * source, rate, 1, syncatten)
        y = recording(f, x, ms, mm, fs, synchronous)
        vald, symloc = Libaudio.decode_syncsymbol(y, s, td, size(source,1)/rate, fs)
        bl = symloc[1]
        br = symloc[1] + round(Int,size(source,1)/rate*fs) - 1
        vals, dbanow = Libaudio.spl(pezo[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")
        dbaadj = dbanow[1]

        if vald && vals && (dbasetting + dbatol ≥ dbaadj ≥ dbasetting - dbatol)
            Libaudio.printl(joinpath(Libaudio.folder(), Libaudio.logfile()), :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::matrix): tolerance satisfied")
            break
        else
            Libaudio.printl(joinpath(Libaudio.folder(), Libaudio.logfile()), :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::matrix): deviation = $(abs(dbaadj-dbasetting)), retry...")
        end
    end
    return (gainadj, dbaadj)
end














#DEPRECATE


"""

# Note
 1) 'symbol' is the segment of signal for level measurement
 2) 'rep' if for multiple trial --- t_context + (symbol + decay) x repeat
 3) 'root' is the path for reference mic recordings of the calibrators (piston and piezo etc...)
 4) validation method 1: compare against the spl meter
    validation method 2: 200hz -> 10dB lower than dBSPL, 1kHz-> the same, 6kHz-> almost the same, 7kHz-> 0.8 dB lower than dBSPL
 5) 'dbasetting' if given NaN then no gain adjustment is applied and the dba measurement corresponds to 'gaininit'
"""
function setdba(
    f,
    symbol::Vector, 
    rep::Int, 
    gaininit, 
    ms::Matrix, 
    mm::Matrix, 
    fs, 
    dbasetting, 
    root,
    piston = Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    piezo = Instrument("42AB",114,114,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    synchronous = true,
    tcs = 3.0,
    td = 2.0,
    maxdayadd = 1,
    maxdaycal = 180,
    barocorrection = 0.0)
    
    @assert nprocs() > 1
    @assert size(ms, 1) == 1
    @assert size(mm, 2) == 1
    @assert now() - DateTime(piston.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))
    @assert now() - DateTime(piezo.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))

    pstnl, pstnd = getlatest(root, piston)
    pezol, pezod = getlatest(root, piezo)

    rootlog = joinpath(Libaudio.folder(), Libaudio.logfile())
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): use latest calibration files:")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): $pstnl")
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): $pezol")

    if maxdayadd > 0
        pstnd ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): calibration is too old")
        pezod ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): calibration is too old")
    end
    wf = Libaudio.WindowFrame(fs,16384,16384÷4)
    pstn, sr = Libaudio.wavread(pstnl, Float64)
    pezo, sr = Libaudio.wavread(pezol, Float64)

    m = length(symbol)
    n = round(Int, td*fs)
    x = zeros(m+n,1)
    x[1:m,1] = symbol * 10^(gaininit/20)
    y = recording(f, [zeros(round(Int,tcs*fs),1); repeat(x,rep,1)], ms, mm, fs, synchronous)  
    
    val = Bool[0,0,0,0]
    val[1], pstnspl = Libaudio.spl(pstn[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piston.dbspl+barocorrection)
    val[2], pezospl = Libaudio.spl(pezo[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piezo.dbspl)
    if abs(pstnspl[1]-pezospl[1]) > 0.5
        Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): calibration deviation > 0.5 dB")
    else
        Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): calibration deviation $(abs(pstnspl[1]-pezospl[1])) dB")
    end

    val[3], pstndba = Libaudio.spl(pezo[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")
    gainadj = isnan(dbasetting) ? gaininit : (gaininit+(dbasetting-pstndba[1]))

    x[1:m,1] = symbol * 10^(gainadj/20)
    y = recording(f, [zeros(round(Int,tcs*fs),1); repeat(x,rep,1)], ms, mm, fs, synchronous)
    val[4], pstndba = Libaudio.spl(pezo[:,1], y, symbol, rep, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")

    return (all(val), gainadj, pstndba[1])
end

# note: source is multichannel sound tracks for spl measurement, it is based on async method, therefore no need for parameter repeat
function setdba(
    f,
    source::Matrix, 
    gaininit, 
    ms::Matrix, 
    mm::Matrix, 
    fs, 
    dbasetting, 
    root,
    piston = Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    piezo = Instrument("42AB",114,114,Date("2018-07-24"),"26XX","12AA",0,"UFX"),
    synchronous = true,
    syncatten = -12,
    tcs = 3.0,
    td = 2.0,
    maxdayadd = 1,
    maxdaycal = 180,
    barocorrection = 0.0,
    fm = fs)
    
    @assert nprocs() > 1
    @assert size(mm,2) == 1
    @assert now() - DateTime(piston.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))
    @assert now() - DateTime(piezo.lastcal) ≤ Dates.Millisecond(Dates.Day(maxdaycal))

    pstnl, pstnd = getlatest(root, piston)
    pezol, pezod = getlatest(root, piezo)

    rootlog = joinpath(Libaudio.folder(), Libaudio.logfile())
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::matrix): use latest calibration files:") 
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::matrix): $pstnl") 
    Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::matrix): $pezol") 

    if maxdayadd > 0
        pstnd ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.setdba(::matrix): calibration is too old") 
        pezod ≥ Dates.Millisecond(Dates.Day(maxdayadd)) && Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.setdba(::matrix): calibration is too old") 
    end
    wf = Libaudio.WindowFrame(fs,16384,16384÷4)
    pstn, sr = Libaudio.wavread(pstnl, Float64)
    pezo, sr = Libaudio.wavread(pezol, Float64)

    val = Bool[0,0,0,0,0,0]
    rate = synchronous ? fs : fm
    s = Libaudio.symbol_expsinesweep(800, 2000, 0.5, rate)
    x = Libaudio.encode_syncsymbol(tcs, s, td, 10^(gaininit/20) * source, rate, 1, syncatten)
    y = recording(f, x, ms, mm, fs, synchronous)
    val[1], symloc = Libaudio.decode_syncsymbol(y, s, td, size(source,1)/rate, fs)
    bl = symloc[1]
    br = symloc[1] + round(Int,size(source,1)/rate*fs) - 1

    val[2], pstnspl = Libaudio.spl(pstn[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piston.dbspl+barocorrection)
    val[3], pezospl = Libaudio.spl(pezo[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piezo.dbspl)
    if abs(pstnspl[1]-pezospl[1]) > 0.5
        Libaudio.printl(rootlog, :light_red, Libaudio.nows() * " | SoundPressureLevel.setdba(::vector): calibration deviation > 0.5 dB")
    else
        Libaudio.printl(rootlog, :light_yellow, Libaudio.nows() * " | SoundPressureLevel.setdba(::matrix): calibration deviation $(abs(pstnspl[1]-pezospl[1])) dB") 
    end

    val[4], pstndba = Libaudio.spl(pezo[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")
    gainadj = isnan(dbasetting) ? gaininit : (gaininit+(dbasetting-pstndba[1]))

    x = Libaudio.encode_syncsymbol(tcs, s, td, 10^(gainadj/20) * source, rate, 1, syncatten)
    y = recording(f, x, ms, mm, fs, synchronous) 
    val[5], symloc = Libaudio.decode_syncsymbol(y, s, td, size(source,1)/rate, fs)
    bl = symloc[1]
    br = symloc[1] + round(Int,size(source,1)/rate*fs) - 1
    
    val[6], pstndba = Libaudio.spl(pezo[:,1], y[bl:br,:], y[bl:br,1], 1, wf, 0, 0, 100, 12000, piezo.dba, weighting="A")
    return (all(val), gainadj, pstndba[1])
end




end # module
