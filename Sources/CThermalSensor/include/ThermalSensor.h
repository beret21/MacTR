// ThermalSensor.h — C interface for IOHIDEventSystemClient temperature reader
#pragma once

/// Read CPU and GPU temperatures via IOHIDEventSystemClient.
/// Returns -1 if sensor not available.
/// No sudo required on Apple Silicon.
void readThermalSensors(double *cpuTemp, double *gpuTemp);
