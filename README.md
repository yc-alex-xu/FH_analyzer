A [Taps](https://wiki.wireshark.org/Lua/Taps) to analyze the O-RAN traffic.

# Feature
In the viewpoint of DU:
* check the UL u-plane missing
* check the UL u-plane timing
* check the DU Tx timing

# Usage
It is tested in Wireshark v3.6 under Windows
* copy the lua files into the folder of Personal Lua Plugins
* reload the plugin via menu: Analyzer--Reload Lua Plugins
* access the plugin via menu: Tools--ORAN

# License
According to https://wiki.wireshark.org/Lua

The code written in Lua that uses bindings to Wireshark must be distributed under the GPL terms. 
