%hArrayGeometry antenna array geometry for CDL channel model

%   Copyright 2018-2022 The MathWorks, Inc.

function cdl = hArrayGeometry(cdl,NTxAnts,NRxAnts,varargin)

    if (nargin==3)
        linkDirection = 'downlink';
    else
        linkDirection = varargin{1};
    end

    if (strcmpi(linkDirection,'downlink'))
        txArray = bsArrayGeometry(cdl.TransmitAntennaArray,NTxAnts);
        rxArray = ueArrayGeometry(cdl.ReceiveAntennaArray,NRxAnts);
    else % uplink
        txArray = ueArrayGeometry(cdl.TransmitAntennaArray,NTxAnts);
        rxArray = bsArrayGeometry(cdl.ReceiveAntennaArray,NRxAnts);
    end

    cdl.TransmitAntennaArray = txArray;
    cdl.ReceiveAntennaArray = rxArray;

    warnIfArraySizeChanged(cdl,NTxAnts,NRxAnts,linkDirection)

end

function array = bsArrayGeometry(array,nBsAnts)

    % Panel configurations, [M N P Mg Ng]: rows and columns per panel,
    % polarizations, then rows and columns in the array of panels.
    %             [M  N   P   Mg  Ng]
    antArraySizes = ...
       [1   1   1   1   1;   % 1 ants
        1   1   2   1   1;   % 2 ants
        2   1   2   1   1;   % 4 ants
        2   2   2   1   1;   % 8 ants
        2   4   2   1   1;   % 16 ants
        4   4   2   1   1;   % 32 ants
        4   4   2   1   2;   % 64 ants
        4   8   2   1   2;   % 128 ants
        4   8   2   2   2;   % 256 ants
        8   8   2   2   2;   % 512 ants
        8  16   2   2   2];  % 1024 ants
    antselected = min(1+ceil(log2(nBsAnts)),size(antArraySizes,1));
    array.Size = antArraySizes(antselected,:);

    % Spacing adjusted to avoid panel overlaps.
    array.ElementSpacing(3) = array.Size(1)*array.ElementSpacing(1);
    array.ElementSpacing(4) = array.Size(2)*array.ElementSpacing(2);

end

function array = ueArrayGeometry(array,nUeAnts)

    if nUeAnts == 1
        arraySize = ones(1,5);
    else
        arraySize = [ceil(nUeAnts/2),1,2,1,1];
    end
    array.Size = arraySize;
    
end

function warnIfArraySizeChanged(channel,NTxAnts,NRxAnts,linkDirection)

    NTxAntsChannel = prod(channel.TransmitAntennaArray.Size);
    NRxAntsChannel = prod(channel.ReceiveAntennaArray.Size);

    side = ["transmit" "receive"];
    if ~strcmpi(linkDirection,'Downlink')
        side = fliplr(side);
    end

    if NTxAntsChannel ~= NTxAnts
        str = 'The number of BS %s antenna elements configured (%d) is not one of the set (1,2,4,8,16,32,64,128,256,512,1024). Using %d instead.';
        warning('nr5g:hArrayGeometry:numAnts',str,side(1),NTxAnts,NTxAntsChannel);
    end
    
    if NRxAntsChannel ~= NRxAnts
        str = 'The number of UE %s antenna elements configured (%d) is not even. Using %d instead.';
        warning('nr5g:hArrayGeometry:numAnts',str,side(2),NRxAnts,NRxAntsChannel);
    end

end