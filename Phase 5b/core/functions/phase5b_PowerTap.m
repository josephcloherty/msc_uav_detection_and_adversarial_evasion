classdef phase5b_PowerTap < handle
%phase5b_PowerTap Absolute received-power tap on the UE-to-gNB packet path.
%
%   TAP = phase5b_PowerTap(GNBIDS, UEIDS, RXGAIN_DB) builds the collector.
%   tr36777ChannelModel writes one entry per uplink packet after pathloss and
%   shadow fading have been applied, and handoverManager reads the entry back
%   when the matching SRS reception event fires.
%
%   SINR is a ratio and carries no absolute level, so RSRP, RSSI and RSRQ
%   cannot be derived from the measurement chain alone. This is the only
%   place in the run where an absolute power figure exists.
%
%   Entries are held per (gNB, UE) pair with the packet start time, and read
%   back only when the entry is no older than MAXLAG_S. A stale entry returns
%   NaN rather than a value from the wrong packet.
%
%   RXGAIN_DB is added on read, so the recorded figure is at the antenna and
%   the returned figure is at the receiver port, matching the reference the
%   toolbox SINR is computed against.

    properties (SetAccess = private)
        rxPower_dBm      % [numGNB x numUE], most recent entry
        stamp_s          % [numGNB x numUE], packet start time of that entry
        gnbIdxByID       % node ID -> row
        ueIdxByID        % node ID -> column
        rxGain_dB = 0
    end

    properties
        maxLag_s = 1e-3;   % one subframe
    end

    methods
        function obj = phase5b_PowerTap(gnbIDs, ueIDs, rxGain_dB)
            gnbIDs = double(gnbIDs(:))';
            ueIDs  = double(ueIDs(:))';
            obj.gnbIdxByID = zeros(1, max([gnbIDs 1]));
            obj.gnbIdxByID(gnbIDs) = 1:numel(gnbIDs);
            obj.ueIdxByID = zeros(1, max([ueIDs 1]));
            obj.ueIdxByID(ueIDs) = 1:numel(ueIDs);
            obj.rxPower_dBm = nan(numel(gnbIDs), numel(ueIDs));
            obj.stamp_s     = nan(numel(gnbIDs), numel(ueIDs));
            if nargin > 2 && ~isempty(rxGain_dB)
                obj.rxGain_dB = rxGain_dB;
            end
        end

        function record(obj, gnbID, ueID, tStart, pRx_dBm)
            g = obj.idxG(gnbID);
            u = obj.idxU(ueID);
            if g == 0 || u == 0, return; end
            obj.rxPower_dBm(g, u) = pRx_dBm;
            obj.stamp_s(g, u)     = tStart;
        end

        function p = read(obj, gnbID, ueID, tNow)
        %read Received power at the port, NaN when no fresh entry exists.
            p = NaN;
            g = obj.idxG(gnbID);
            u = obj.idxU(ueID);
            if g == 0 || u == 0, return; end
            lag = tNow - obj.stamp_s(g, u);
            if isnan(lag) || lag < 0 || lag > obj.maxLag_s, return; end
            p = obj.rxPower_dBm(g, u) + obj.rxGain_dB;
        end
    end

    methods (Access = private)
        function g = idxG(obj, id)
            if id >= 1 && id <= numel(obj.gnbIdxByID)
                g = obj.gnbIdxByID(id);
            else
                g = 0;
            end
        end

        function u = idxU(obj, id)
            if id >= 1 && id <= numel(obj.ueIdxByID)
                u = obj.ueIdxByID(id);
            else
                u = 0;
            end
        end
    end

    methods (Static)
        function [rsrp, rssi, rsrq] = derive(pRx_dBm, sinr_dB, numRB)
        %derive RSRP, RSSI and RSRQ from one packet, per TS 38.215.
        %
        %   PRX_DBM is the wideband received power of the SRS transmission and
        %   SINR_DB the toolbox measurement for the same packet.
        %
        %     RSRP = PRX - 10*log10(12*numRB)      power per resource element
        %     P_IN = PRX - SINR                    interference plus noise
        %     RSSI = 10*log10(10^(PRX/10) + 10^(P_IN/10))
        %     RSRQ = 10*log10(numRB) + RSRP - RSSI
        %
        %   Deriving the interference-plus-noise term from the SINR rather
        %   than from an assumed noise figure keeps the three consistent with
        %   the SINR the rest of the pipeline already records.
        %
        %   These are uplink SRS quantities measured at the gNB, not the
        %   downlink UE reports of TS 38.215; the substitution is the same one
        %   the deviations log records for the handover metric, and it keeps
        %   every column operator-side and unfalsifiable by the UE. The
        %   per-resource-element normalisation is a fixed offset, so the
        %   columns are monotone in the standard definitions.
            rsrp = NaN; rssi = NaN; rsrq = NaN;
            if isempty(pRx_dBm) || isempty(sinr_dB) || isempty(numRB), return; end
            if isnan(pRx_dBm) || isnan(sinr_dB) || isnan(numRB) || numRB < 1
                return;
            end

            rsrp = pRx_dBm - 10*log10(12 * numRB);
            pIN  = pRx_dBm - sinr_dB;
            rssi = 10*log10(10.^(pRx_dBm/10) + 10.^(pIN/10));
            rsrq = 10*log10(numRB) + rsrp - rssi;
        end
    end
end
