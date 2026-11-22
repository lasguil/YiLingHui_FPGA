"""G4Net: RGB frame -> four logits, or (v5 on) a hand-centre heatmap alone, with
foldable Conv/BN/ReLU6 blocks.

Construction does not run inference. Callers must explicitly place model and
inputs on CUDA for training/inference, as required by the project.

The body is identical in every version, so the position head added for v5 is the
only new path here: it taps one named block and applies a single 1x1 convolution
without an activation. v5 has no `classifier` section, so it has no GAP and no
FC either -- its only output is the heatmap. Configs with a classifier keep the
exact v1-v4 behaviour and return a bare logit tensor; checkpoints of v1-v4 load
into this class unchanged, their module names and shapes are untouched.
"""
from collections import OrderedDict
from copy import deepcopy

import torch
from torch import nn
from torch.nn.utils.fusion import fuse_conv_bn_eval

from .spec import load_config


class ConvBNAct(nn.Module):
    def __init__(self, cin, cout, kernel, stride=1, groups=1):
        super().__init__()
        self.conv = nn.Conv2d(cin, cout, kernel, stride, kernel // 2,
                              groups=groups, bias=False)
        self.bn = nn.BatchNorm2d(cout)
        self.act = nn.ReLU6(inplace=False)

    def forward(self, x):
        return self.act(self.bn(self.conv(x)))


class ConvBN(nn.Module):
    """Conv + BN with no activation, for a head whose output range is signed.

    A heatmap has to fall to (and below) zero away from the hand, so the ReLU6
    of the body would clip exactly the half of the range that carries "no hand
    here". This is the only structural difference from `ConvBNAct`.
    """

    def __init__(self, cin, cout, kernel, stride=1):
        super().__init__()
        self.conv = nn.Conv2d(cin, cout, kernel, stride, kernel // 2, bias=False)
        self.bn = nn.BatchNorm2d(cout)

    def forward(self, x):
        return self.bn(self.conv(x))


class DepthwiseSeparable(nn.Module):
    def __init__(self, cin, cout, stride):
        super().__init__()
        self.dw = ConvBNAct(cin, cin, 3, stride, groups=cin)
        self.pw = ConvBNAct(cin, cout, 1)

    def forward(self, x):
        return self.pw(self.dw(x))


class G4Net(nn.Module):
    def __init__(self, config=None):
        super().__init__()
        self.config = load_config(config)
        self.class_keys = tuple(c['key'] for c in self.config['classes'])
        cin = self.config['input']['channels']
        blocks = OrderedDict()
        for block in self.config['blocks']:
            cout = block['out_channels']
            if block['type'] == 'conv':
                layer = ConvBNAct(cin, cout, block['kernel'], block['stride'])
            else:
                layer = DepthwiseSeparable(cin, cout, block['stride'])
            blocks[block['name']] = layer
            cin = cout
        self.features = nn.Sequential(blocks)
        position = self.config.get('position_head')
        classifier = self.config.get('classifier')
        if classifier:
            self.pool = nn.AdaptiveAvgPool2d(1)
            self.classifier = nn.Linear(cin, classifier['out_features'])
        else:
            # A position-only model: nothing reduces the feature map, so there is
            # no GAP and no FC. The heatmap is the network's whole output.
            self.pool = None
            self.classifier = None
        if position is None:
            self.position = None
            self.tap_index = None
        else:
            names = [block['name'] for block in self.config['blocks']]
            self.tap_index = names.index(position['tap'])
            tap_channels = self.config['blocks'][self.tap_index]['out_channels']
            self.position = ConvBN(tap_channels, position['out_channels'],
                                   position['kernel'])
            # Start the head as a constant, low map: a heatmap head that begins
            # near 0.5 loses to the ~570 background cells that all want it lower,
            # and training settles on a flat map with no peak anywhere
            # (measured). Starting at 0.01 leaves the positive term room to pull
            # the peak up; the small input weight keeps gradients flowing.
            with torch.no_grad():
                self.position.bn.weight.fill_(0.01)
                self.position.bn.bias.fill_(position.get('head_bias_init', -4.6))

    def forward(self, x):
        """Logits, or the hand-centre heatmap, or `{'logits', 'heatmap'}`.

        The heatmap is taken as soon as its source block is computed, so the
        order of operations here is the order the board will run: the tap layer
        is a layer in the same stream, not a second pass.
        """
        heatmap = None
        if self.position is None:
            x = self.features(x)
        else:
            for index, layer in enumerate(self.features):
                x = layer(x)
                if index == self.tap_index:
                    heatmap = self.position(x)
        if self.classifier is None:
            return heatmap
        logits = self.classifier(torch.flatten(self.pool(x), 1))
        if heatmap is None:
            return logits
        return {'logits': logits, 'heatmap': heatmap}

    def to_deploy(self):
        """Return an independent FP32 eval model with BN folded; not INT8 export.

        The position head is left as a logit, like the classifier: the sigmoid
        named in the config belongs to the INT8 export contract, next to the
        activations and the requantisation scales, not to this fold.
        """
        if self.training:
            raise ValueError('Call model.eval() before folding BatchNorm.')
        deployed = deepcopy(self)
        for module in deployed.modules():
            if (isinstance(module, (ConvBNAct, ConvBN))
                    and isinstance(module.bn, nn.BatchNorm2d)):
                module.conv = fuse_conv_bn_eval(module.conv, module.bn)
                module.bn = nn.Identity()
        return deployed
