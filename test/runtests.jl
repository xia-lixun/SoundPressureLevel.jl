import SoundPressureLevel

using Test
using Dates
using Libaudio
@everywhere using DeviceUnderTest

function simple_test()

    r = DeviceUnderTest.register()
    ms = zeros(1,8)
    ms[1,1] = 1
    mm = zeros(8,1)
    mm[1,1] = 1
    s,fs = Libaudio.wavread_("test/acqua_ieee_male_250ms_10450ms.wav", Float64)
    SoundPressureLevel.setdba(
        r[0x9fefe994b7e95bf1], 
        s[:,1], 
        1, 
        -6, 
        ms, 
        mm, 
        48000, 
        57, 
        "D:/Depot\\Git\\SoundPressureLevel.jl\\foo\\", 
        SoundPressureLevel.Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFS"), 
        SoundPressureLevel.Instrument("42AB",114,NaN,Date("2018-07-24"),"26XX","12AA",0,"UFS"), 
        false)

    SoundPressureLevel.setdba(
        r[0x9fefe994b7e95bf1], 
        s[:,2], 
        1, 
        -6, 
        ms, 
        mm, 
        48000, 
        57, 
        "D:/Depot\\Git\\SoundPressureLevel.jl\\foo\\", 
        SoundPressureLevel.Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFS"), 
        SoundPressureLevel.Instrument("42AB",114,NaN,Date("2018-07-24"),"26XX","12AA",0,"UFS"))

    SoundPressureLevel.setdba(
        r[0x9fefe994b7e95bf1],
        s[:,2:2], 
        -6, 
        ms, 
        mm, 
        48000, 
        60, 
        "D:/Depot\\Git\\SoundPressureLevel.jl\\foo\\",
        SoundPressureLevel.Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFS"), 
        SoundPressureLevel.Instrument("42AB",114,NaN,Date("2018-07-24"),"26XX","12AA",0,"UFS"))

    SoundPressureLevel.setdba(
        r[0x9fefe994b7e95bf1],
        s[:,1:1], 
        -6, 
        ms, 
        mm, 
        48000, 
        60, 
        "D:/Depot\\Git\\SoundPressureLevel.jl\\foo\\",
        SoundPressureLevel.Instrument("42AA",114,105.4,Date("2018-07-24"),"26XX","12AA",0,"UFS"), 
        SoundPressureLevel.Instrument("42AB",114,NaN,Date("2018-07-24"),"26XX","12AA",0,"UFS"),
        false,
        -10,
        3.0,
        2.0,
        1,
        180,
        0.0,
        47999.6)
end