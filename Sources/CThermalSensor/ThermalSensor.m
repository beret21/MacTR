// ThermalSensor.m — IOHIDEventSystemClient-based temperature reader
//
// Reads CPU and GPU temperature on Apple Silicon without sudo.
// Based on fermion-star/apple_sensors, which is derived from
// freedomtan/sensors (sensors/sensors.m). Original license:
//
// BSD 3-Clause License
//
// Copyright (c) 2016-2018, "freedom" Koan-Sin Tan
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
//
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// * Neither the name of the copyright holder nor the names of its
//   contributors may be used to endorse or promote products derived from
//   this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Uses private IOKit HID API: IOHIDEventSystemClient.
//
// IMPORTANT: IOHIDEventSystemClient is created ONCE and reused
// to prevent memory leak (~4GB over hours of 0.5s polling).

#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <Foundation/Foundation.h>
#include "ThermalSensor.h"

// Private IOKit declarations (not in public headers)
typedef struct __IOHIDEvent *IOHIDEventRef;
#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);

#define IOHIDEventFieldBase(type) (type << 16)
#define kIOHIDEventTypeTemperature 15

// Persistent state — created once, reused across calls
static IOHIDEventSystemClientRef _system = NULL;
static CFDictionaryRef _match = NULL;

static void ensureInitialized(void) {
    if (_system) return;

    int page = 0xff00;
    int usage = 0x0005;
    CFNumberRef nums[2];
    CFStringRef keys[2];
    keys[0] = CFStringCreateWithCString(0, "PrimaryUsagePage", 0);
    keys[1] = CFStringCreateWithCString(0, "PrimaryUsage", 0);
    nums[0] = CFNumberCreate(0, kCFNumberSInt32Type, &page);
    nums[1] = CFNumberCreate(0, kCFNumberSInt32Type, &usage);
    _match = CFDictionaryCreate(0, (const void**)keys, (const void**)nums, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(keys[0]); CFRelease(keys[1]);
    CFRelease(nums[0]); CFRelease(nums[1]);

    _system = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    IOHIDEventSystemClientSetMatching(_system, _match);
}

void readThermalSensors(double *cpuTemp, double *gpuTemp) {
    *cpuTemp = -1;
    *gpuTemp = -1;

    ensureInitialized();
    if (!_system) return;

    CFArrayRef services = IOHIDEventSystemClientCopyServices(_system);
    if (!services) return;

    long count = CFArrayGetCount(services);
    double cpuMax = 0, gpuMax = 0;
    int cpuFound = 0, gpuFound = 0;

    for (int i = 0; i < count; i++) {
        IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(sc, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) continue;

        double temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
        CFRelease(event);

        if (temp <= 0 || temp > 150) continue;

        CFStringRef name = IOHIDServiceClientCopyProperty(sc, CFSTR("Product"));
        if (!name) continue;

        NSString *sensorName = (__bridge NSString *)name;

        if ([sensorName containsString:@"PMU tdie"] ||
            [sensorName containsString:@"CPU"] ||
            [sensorName containsString:@"pACC"] ||
            [sensorName containsString:@"eACC"]) {
            if (temp > cpuMax) cpuMax = temp;
            cpuFound = 1;
        }
        else if ([sensorName containsString:@"GPU"] ||
                 ([sensorName hasPrefix:@"PMU TP"] && [sensorName hasSuffix:@"g"])) {
            if (temp > gpuMax) gpuMax = temp;
            gpuFound = 1;
        }

        CFRelease(name);
    }

    if (cpuFound) *cpuTemp = cpuMax;
    if (gpuFound) *gpuTemp = gpuMax;

    CFRelease(services);
}
