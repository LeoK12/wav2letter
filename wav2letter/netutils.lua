require 'nn'
require 'fbcunn'
local argcheck = require 'argcheck'
local optim = require 'torchnet.optim'

local netutils = {}

local function isz(oikw, oidw, kw, dw)
   dw = dw or 1
   oikw = oikw*dw + kw-dw
   oidw = oidw*dw
   return oikw, oidw
end

function netutils.readspecs(filename)
   local f = io.open(filename)
   local specs = f:read('*all')
   f:close()
   return specs
end

netutils.create = argcheck{
   {name="specs", type="string"},
   {name="gpu", type="number"},
   {name="nchannel", type="number"},
   {name="nclass", type="number"},
   {name="lsm", type="boolean"},
   call =
      function(specs, gpu, nchannel, nclass, lsm)
         local net = nn.Sequential()

         local TemporalConvolution
         local TemporalMaxPooling
         local TemporalAveragePooling
         local FeatureLPPooling
         local Tanh
         local Add
         local Log
         local ReLU
         local HardTanh
         local TanhLinear
         local Linear
         local Dropout
         if gpu > 0 then
            require 'cunn'
            require 'fbcunn'
            require 'cudnn'
            cudnn.fastest = true --Much better performance!
            net:add( nn.Copy('torch.FloatTensor', 'torch.CudaTensor', true, true) )
            net:add( nn.Transpose{1, 2}:cuda() )
            net:add( nn.View(nchannel, 1, -1):cuda() )

            function TemporalConvolution(nin, nout, kw, dw)
               return cudnn.SpatialConvolution(nin, nout, kw, 1, dw, 1):cuda()
            end

            function Linear(nin, nout)
               return nn.Linear(nin, nout):cuda()
            end

            function Dropout(nsz)
               return nn.Dropout(nsz):cuda()
            end

            function TemporalMaxPooling(kw, dw)
               return cudnn.SpatialMaxPooling(kw, 1, dw, 1):cuda()
            end

            function TemporalAveragePooling(kw, dw)
               return nn.SpatialAveragePooling(kw, 1, dw, 1):cuda()
            end

            function FeatureLPPooling(batch_mode)
               batch_mode = batch_mode or false
               return nn.FeatureLPPooling(2, 2, 2, batch_mode):cuda()
            end

            function Tanh()
               return nn.Tanh():cuda()
            end

            function TanhLinear(size, stride)
               return nn.TanhLinear(size, stride):cuda()
            end

            function Add(scale)
               return nn.Add(scale,true):cuda()
            end

            function Log()
               return nn.Log():cuda()
            end

            function ReLU()
               return nn.ReLU():cuda()
            end

            function HardTanh()
               return nn.HardTanh():cuda()
            end

         else
            TemporalConvolution = nn.TemporalConvolution
            TemporalMaxPooling = nn.TemporalMaxPooling
            Tanh = nn.Tanh
            TanhLinear = nn.TanhLinear
            HardTanh = nn.HardTanh
            Linear = nn.Linear
            Dropout = nn.Dropout
            function TemporalAveragePooling(kw, dw)
               return nn.SpatialAveragePooling(kw, 1, dw, 1)
            end
            function FeatureLPPooling(batch_mode)
               batch_mode = batch_mode or false
               return nn.FeatureLPPooling(2, 2, 2, batch_mode)
            end
            function Add(scale)
               return nn.Add(scale,true)
            end
            function Log()
               return nn.Log()
            end
            function ReLU()
               return nn.ReLU()
            end

         end

         -- LogSoftMax might be only at the very end
         local haslsm = specs:match('\n%s*LSM%s*$')
         if haslsm then
            specs = specs:gsub('\n%s*LSM%s*$', '')
         end

         local kwdw = {}
         local osz = nchannel
         local hastrans = false
         for line in specs:gmatch('[^\n]+') do
            if not line:match('^#') then
               line = line:gsub('NCHANNEL', nchannel)
               line = line:gsub('NLABEL', nclass)

               local cisz, cosz, ckw, cdw = line:match('^%s*C%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s*$')
               local lisz, losz = line:match('^%s*L%s+(%d+)%s+(%d+)%s*$')
               local mkw, mdw = line:match('^%s*M%s+(%d+)%s+(%d+)%s*$')
               local akw, adw = line:match('^%s*A%s+(%d+)%s+(%d+)%s*$')
               local h = line:match('^%s*H%s*$')
               local r = line:match('^%s*R%s*$')
               local hls, hle = line:match('^%s*HL%s+(%d+)%s+(%d+)%s*$')
               local as = line:match('^%s*AD%s+(%d+)%s*$')
               local l = line:match('^%s*L%s*$')
               local hh = line:match('^%s*HT%s*$')
               local flp = line:match('^%s*FLP%s*$')
               local donsz = line:match('^%s*DO%s+(%S+)%s*$')

               cisz, cosz, ckw, cdw = tonumber(cisz), tonumber(cosz), tonumber(ckw), tonumber(cdw)
               mkw, mdw = tonumber(mkw), tonumber(mdw)
               lisz, losz = tonumber(lisz), tonumber(losz)
               donsz = tonumber(donsz)

               if cisz and cosz and ckw and cdw then
                  assert(cisz == osz, 'layer size mismatch')
                  assert(gpu <= 0 or not hastrans, 'cannot add a convolutional layer after a linear one')
                  net:add( TemporalConvolution(cisz, cosz, ckw, cdw) )
                  table.insert(kwdw, {kw=ckw, dw=cdw})
               elseif mkw and mdw then
                  assert(gpu <= 0 or not hastrans, 'cannot add a convolutional layer after a linear one')
                  net:add( TemporalMaxPooling(mkw, mdw) )
                  table.insert(kwdw, {kw=mkw, dw=mdw})
               elseif akw and adw then
                  assert(gpu <= 0 or not hastrans, 'cannot add a convolutional layer after a linear one')
                  net:add( TemporalAveragePooling(akw, adw) )
                  table.insert(kwdw, {kw=akw, dw=adw})
               elseif lisz and losz then
                  print("current osz", osz, lisz)
                  assert(lisz == osz, 'layer size mismatch')
                  if gpu > 0 and not hastrans then
                     net:add( nn.View(osz, -1):cuda() )
                     net:add( nn.Transpose{1, 2}:cuda() )
                     hastrans = true
                  end
                  net:add( Linear(lisz, losz) )
               elseif donsz then
                  net:add( Dropout(donsz) )
               elseif h then
                  net:add( Tanh() )
               elseif r then
                  net:add( ReLU() )
               elseif hls and hle then
                  net:add( TanhLinear(hls, hle) )
               elseif as then
                  net:add( Add(as) )
               elseif l then
                  net:add( Log() )
               elseif hh then
                  net:add( HardTanh() )
               elseif flp then
                  net:add( FeatureLPPooling() )
                  osz = osz / 2
               else
                  error(string.format('unrecognized layer <%s>', line))
               end

               osz = cosz or losz or osz
            end
         end

         local oikw, oidw = 0, 1
         for i=#kwdw,1,-1 do
            oikw, oidw = isz(oikw, oidw, kwdw[i].kw, kwdw[i].dw)
         end
         oikw = oikw + oidw

         if gpu > 0 then
            if not hastrans then
               net:add( nn.View(osz, -1):cuda() )
               net:add( nn.Transpose{1, 2}:cuda() )
            end
            if haslsm then
               net:add( nn.LogSoftMax():cuda() )
            end
            net:add( nn.Copy('torch.CudaTensor', 'torch.FloatTensor', true, true) )
         else
            if haslsm or lsm then
               net:add( nn.LogSoftMax() )
            end
         end

         print('[network]')
         print(net)
         print(string.format('[network kw=%s dw=%s]', oikw, oidw))
         return net, oikw, oidw
      end
}

function netutils.size(src)
   local params = src:parameters()
   local size = 0
   for i=1,#params do
      size = size + params[i]:nElement()
   end
   return size
end

--Return network that applies momentum before updating
function netutils.momentum(network, momentum)
   print('| Using momentum: ' .. momentum)
   for i,module in ipairs(network.modules) do
      local w =  network.modules[i].weight
      local dw = network.modules[i].gradWeight
      if w and dw then
         local applyMomentum = optim.momentum(module)
         local oldUpdateParameters = module.updateParameters
         function module.updateParameters(self, lr)
            applyMomentum(momentum)
            return oldUpdateParameters(self, lr)
         end
         print('(' .. i .. ') momentum ' .. momentum)
      end
   end
   return network
end

--Return network that scales learning rate by number of inputs
function netutils.layerlr(network, lr)
   print('| Using layerwise learning rates!')
   for i,module in ipairs(network.modules) do
      local w =  network.modules[i].weight
      local dw = network.modules[i].gradWeight
      if w and dw then
         local oldUpdateParameters = module.updateParameters
         local numel = 0
         if torch.typename(module) == 'cudnn.SpatialConvolution' then
            numel = module.kW*module.kH*module.nInputPlane
         elseif torch.typename(module) == 'nn.SpatialConvolution' then
            numel = module.kW*module.kH*module.nInputPlane
         elseif torch.typename(module) == 'nn.Linear' then
            numel = module.weight:size(2)
         else
            error('unknown layer type')
         end
         function module.updateParameters(self, lr)
            return oldUpdateParameters(self, lr/numel)
         end
         print('(' .. i .. ') lr ' .. lr/numel)
      end
   end
   return network
end

function netutils.copy(dst, src)
   local dstparams = dst:parameters()
   local srcparams = src:parameters()
   assert(#dstparams == #srcparams)
   for i=1,#dstparams do
      dstparams[i]:copy(srcparams[i])
   end
   return dst
end

return netutils
