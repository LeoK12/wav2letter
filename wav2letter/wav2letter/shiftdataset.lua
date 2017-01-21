local tnt = require 'torchnet.env'
local argcheck = require 'argcheck'

local ShiftDataset =
   torch.class('tnt.ShiftDataset', 'tnt.Dataset', tnt)

ShiftDataset.__init = argcheck{
   {name='self', type='tnt.ShiftDataset'},
   {name='dataset', type='tnt.Dataset'},
   {name='shift', type='number'},
   {name='dshift', type='number'},
   {name='setshift', type='function'},
   call =
      function(self, dataset, shift, dshift, setshift)
         assert(shift > 0)
         self.dataset = dataset
         self.shift = shift
         self.dshift = dshift
         self.setshift = setshift
      end
}

ShiftDataset.size = argcheck{
   {name='self', type='tnt.ShiftDataset'},
   call =
      function(self)
         return self.dataset:size()
      end
}

ShiftDataset.get = argcheck{
   {name='self', type='tnt.ShiftDataset'},
   {name='idx', type='number'},
   call =
      function(self, idx)
         local input = {}
         local target
         for n=1,self.shift do
            local shift = (n-1)*self.dshift
            self.setshift(shift)
            local sample = self.dataset:get(idx)
            input[n] = sample.input
            target = sample.target -- should be same
         end
         return {input=input, target=target}
      end
}
