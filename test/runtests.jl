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
    s,fs = Libaudio.wavread("test/acqua_ieee_male_250ms_10450ms.wav", "double")
    SoundPressureLevel.setdba(
        r[hash("lux")], 
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
end