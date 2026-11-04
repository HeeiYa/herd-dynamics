class_name SimulationDelivery
extends RefCounted
## A bounded FIFO element. Metadata has no full store, resource or intent copy.
var sequence: int
var notices: Array[SimulationNotice] = []
var metrics: SimulationTelemetry
