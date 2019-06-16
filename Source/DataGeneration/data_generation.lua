--- Generates neural net training data by solving random poker situations.
-- @module data_generation
local arguments = require 'Settings.arguments'
local game_settings = require 'Settings.game_settings'
local card_generator = require 'DataGeneration.random_card_generator'
local card_to_string_conversion = require 'Game.card_to_string_conversion'
local constants = require 'Settings.constants'
local tools = require 'tools'
require 'DataGeneration.range_generator'
require 'TerminalEquity.terminal_equity'
require 'Lookahead.lookahead'
require 'Lookahead.resolving'

local M = {}

--- Generates training files by sampling random poker
-- situations and solving them.
--
-- @param train_data_count the number of training examples to generate
-- @param file_name name of training file
-- @param street current street
function M:generate_data(train_data_count, file_name, street)
  --data generation
  local timer = torch.Timer()
  timer:reset()
  print('Generating data ...')
  self:generate_data_file(train_data_count, file_name, street)
  print('Generation time: ' .. timer:time().real)
end

--- Generates data files containing examples of random poker situations with
-- counterfactual values from an associated solution.
-- 
-- Each poker situation is randomly generated using @{range_generator} and
-- @{random_card_generator}. For description of neural net input and target
-- type, see @{net_builder}.
-- 
-- @param data_count the number of examples to generate
-- @param file_name the prefix of the files where the data is saved (appended
-- with `.inputs`, `.targets`, and `.mask`).
-- @param street current street
function M:generate_data_file(data_count, file_name, street)
  local range_generator = RangeGenerator()
  local batch_size = arguments.gen_batch_size
  assert(data_count % batch_size == 0, 'data count has to be divisible by the batch size')
  local batch_count = data_count / batch_size

  local target_size = game_settings.hand_count * constants.players_count
  local targets = arguments.Tensor(batch_size, target_size)
  local input_size = game_settings.hand_count * constants.players_count + 1
  local inputs = arguments.Tensor(batch_size, input_size)
  local mask = arguments.Tensor(batch_size, game_settings.hand_count):zero()

  local te = TerminalEquity()
  local startTime = torch.Timer()
  
  local train_folder = tools:get_trianing_path(street, game_settings.nl)

  --calculate min, max and range pot
  local min_pot, max_pot = tools:get_pot_size(street, game_settings.nl)

  local pot_range = {}

  for i = 1, #min_pot do
    pot_range[i] = max_pot[i] - min_pot[i]
  end

  startTime:reset()
  for batch = 1, batch_count do
    local timer = torch.Timer()
    timer:reset()
    local board = card_generator:generate_cards(game_settings.board_card_count[street])

    local board_string = card_to_string_conversion:cards_to_string(board)

    te:set_board(board)
    range_generator:set_board(te, board)

    --generating ranges
    local ranges = arguments.Tensor(constants.players_count, batch_size, game_settings.hand_count)
    for player = 1, constants.players_count do
      range_generator:generate_range(ranges[player])
    end

    --generating pot sizes between ante and stack - 0.1
    local random_pot_cat = torch.rand(1):mul(#min_pot):add(1):floor()[1]
    local random_pot_size = torch.rand(1)[1]

    random_pot_size = random_pot_size * pot_range[random_pot_cat]
    random_pot_size = random_pot_size + min_pot[random_pot_cat]
    random_pot_size = math.floor(random_pot_size)

    --pot features are pot sizes normalized between (ante/stack,1)
    local pot_size_feature = game_settings.nl and (random_pot_size / arguments.stack) or (random_pot_size / max_pot[3])

    --translating ranges to features
    local pot_feature_index = -1
    inputs[{{}, pot_feature_index}]:fill(pot_size_feature)

    local player_indexes = {{1, game_settings.hand_count}, {game_settings.hand_count + 1, game_settings.hand_count * 2}}
    for player = 1, constants.players_count do
      local player_index = player_indexes[player]
      inputs[{{}, player_index}]:copy(ranges[player])
    end

    --computation of values using re-solving
    local values = arguments.Tensor(batch_size, constants.players_count, game_settings.hand_count)

    local pot_size = random_pot_size
    print(board_string .. ' ' .. batch .. ' ' .. pot_size)

    local resolving = Resolving(te)
    local current_node = {}

    current_node.board = board
    current_node.street = street
    current_node.num_bets = 0
    current_node.current_player = street == 1 and constants.players.P1 or constants.players.P2

    --TODO merge preflop bets support
    current_node.bets = arguments.Tensor{pot_size, pot_size}
    local p1_range = ranges[1]
    local p2_range = ranges[2]
    resolving:resolve_first_node(current_node, p1_range, p2_range)
    local root_values = resolving:get_root_cfv_both_players()
    root_values:mul(1 / pot_size)

    values:copy(root_values)

    for player = 1, constants.players_count do
      local player_index = player_indexes[player]
      targets[{{}, player_index}]:copy(values[{{}, player, {}}])
    end

    local basename = file_name .. '-' .. board_string .. '-' .. batch

    torch.save(arguments.data_path .. train_folder .. basename .. '.inputs', inputs:float())
    torch.save(arguments.data_path .. train_folder .. basename .. '.targets', targets:float())
    
    print('avgTime: ' .. (startTime:time().real / batch))
    
  end
end

return M
