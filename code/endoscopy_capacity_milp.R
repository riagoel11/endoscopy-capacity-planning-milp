#---------------------------------------------------------
# 1. Load libraries 
#---------------------------------------------------------
library(ompr)
library(ompr.roi)
library(ROI)
library(ROI.plugin.highs)
library(dplyr)
library(ggplot2)

#---------------------------------------------------------
# 2. Indices 
#---------------------------------------------------------
R <- 10
W <- 26

rooms <- 1:R #r for rooms
weeks <- 1:W #w for weeks 

#---------------------------------------------------------
# 3. Input Data 
#---------------------------------------------------------
# Diagnostic demand
P_diag <- c(230,235,225,230,240,245,280,295,300,285,240,235,230,
            225,230,235,240,245,250,245,240,235,230,230,235,230)

# Therapeutic demand
P_thera <- c(145,145,150,150,155,160,168,176,182,188,190,192,188,
             195,187,182,178,172,168,165,162,158,155,152,150,148)

# Staff availability
C <- c(520,515,525,520,530,525,490,480,485,500,510,515,520,525,
       530,525,520,480,470,475,500,510,515,520,525,530)

#Room Parameters 
# Diagnostic capacity
B_diag <- c(rep(60,3), rep(120,4), rep(180,3))

# Therapeutic capacity
B_thera <- c(rep(30,3), rep(60,4), rep(120,3))

# Setup cost
S <- c(rep(15000,3), rep(20000,4), rep(25000,3))

# Cost per hour
A <- c(rep(180,3), rep(200,4), rep(220,3))

#---------------------------------------------------------
# 4. MILP Model Training
#---------------------------------------------------------
model <- MIPModel() %>%
  
  ##Adding the required variables 
  # Binary variable: 1 if room r is diagnostic in week w
  add_variable(x_diag[r,w], r = 1:10, w = 1:26, type = "binary") %>%
  
  # Binary variable: 1 if room r is therapeutic in week w
  add_variable(x_thera[r,w], r = 1:10, w = 1:26, type = "binary") %>%
  
  # Binary setup variable
  add_variable(y[r,w], r = 1:10, w = 1:26, type = "binary") %>%
  
  # Diagnostic hours
  add_variable(d[r,w] , r = 1:10, w = 1:26, lb=0) %>%
  
  # Therapeutic hours
  add_variable(t[r,w] , r = 1:10, w = 1:26, lb=0) %>% 
  
  
  ##Constraints based on question ( Used AI to debug )
  # Constraint 1: A room can be assigned to either diagnostic or therapeutic
  #procedures in a week, but not both
  add_constraint(x_diag[r,w] + x_thera[r,w] <= 1,r = rooms, w = weeks) %>% 
  
  # Constraint 2: Total diagnostic procedures across all rooms in each week
  #must satisfy the required diagnostic demand
  add_constraint(sum_expr(d[r,w], r = rooms) >= P_diag[w],w = weeks) %>% 
  
  # Constraint 3: Total therapeutic procedures across all rooms in each week
  #must satisfy the required therapeutic demand
  add_constraint(sum_expr(t[r,w], r = rooms) >= P_thera[w],w = weeks) %>%
  
  # Constraint 4: Therapeutic procedures can only be performed in a room if
  #that room is assigned to therapeutic use and  procedures cannot exceed its therapeutic capacity
  add_constraint(
    t[r,w] <= B_thera[r]*x_thera[r,w],r = rooms, w = weeks ) %>%
  
  # Constraint 5: Total procedures performed in a room cannot exceed the 
  #capacity  in that week
  add_constraint(
    d[r,w] + t[r,w] <= B_diag[r]*x_diag[r,w] + 
      B_thera[r]*x_thera[r,w],r = rooms, w = weeks) %>%
  
  # Constraint 6: Total procedures performed across all rooms in a week 
  #cannot exceed the overall weekly hospital capacity
  add_constraint(
    sum_expr(d[r,w] + t[r,w], r = rooms) <= C[w], w = weeks) %>%
  
  # Constraint 7: If a room is used in week 1 , it counts as an opening of that room
  add_constraint(
    y[r,1] >= x_diag[r,1] + x_thera[r,1], r = rooms) %>%
  
  # Constraint 8: Detects a new room opening when a room becomes active in
  #week w but was inactive in week w-1
  add_constraint(
    y[r,w] >= (x_diag[r,w] + x_thera[r,w]) -
      (x_diag[r,w-1] + x_thera[r,w-1]),r = rooms, w = 2:W) %>% 
  
  # Constraint 9: Ensures the room opening variable can only be 1 if the room
  #is actually active in that week
  add_constraint(y[r,w] <= x_diag[r,w] + x_thera[r,w], r= 1:10, w=2:W) 


##-----------------------------------------------------------------------------
# 5.Objective Function 
##-----------------------------------------------------------------------------
model <- model %>%
  set_objective(
    ## Allocation cost for thera and diag 
    sum_expr( A[r] * B_diag[r] * x_diag[r,w] +
                
                A[r] * B_thera[r] * x_thera[r,w] ,r = rooms, w = weeks ) +
      #Setup costs wherever applied 
      sum_expr(S[r] * y[r,w], r = rooms, w = weeks),
    "min"
  )


#---------------------------------------------------------
# 6. Solving the model 
#---------------------------------------------------------

result <- solve_model(model,with_ROI(solver = "highs",verbose = TRUE ))

#---------------------------------------------------------
# 7. Solver Results Summary
#---------------------------------------------------------

solver_summary <- data.frame(
  Metric = c(
    "Solver Status",
    "Objective Value (Total Cost)",
    "Number of Rooms",
    "Planning Horizon (Weeks)"
  ),
  Value = c(
    result$status,
    round(objective_value(result),2),
    R,
    W
  )
)

gt(solver_summary) %>%
  tab_header(
    title = md("**Optimisation Solver Results**"),
    subtitle = "Summary of optimisation outcome"
  ) %>%
  cols_align(align = "center")

#---------------------------------------------------------
# 8. Extract Optimal Solution
#---------------------------------------------------------

x_diag_sol <- get_solution(result, x_diag[r,w])
x_thera_sol <- get_solution(result, x_thera[r,w])
d_sol <- get_solution(result, d[r,w])
t_sol <- get_solution(result, t[r,w])
setup_sol <- get_solution(result, y[r,w])

#---------------------------------------------------------
# 9. Create Room Level Dataset ( Used AI for the structure and adapted according to requirements)
#---------------------------------------------------------

table_data <- x_diag_sol %>%
  
  rename(x_diag = value) %>%
  
  left_join(x_thera_sol %>% rename(x_thera = value),
            by = c("r","w")) %>%
  
  left_join(d_sol %>% rename(d_hours = value),
            by = c("r","w")) %>%
  
  left_join(t_sol %>% rename(t_hours = value),
            by = c("r","w")) %>%
  
  left_join(setup_sol %>% rename(setup = value),
            by = c("r","w")) %>%
  
  mutate(
    room_type = case_when(
      x_diag > 0.5 ~ "Diagnostic",x_thera > 0.5 ~ "Therapeutic",
      TRUE ~ "Unused"),
    total_hours = d_hours + t_hours)

#---------------------------------------------------------
# 10. Weekly Results Summary
#---------------------------------------------------------

weekly_summary <- table_data %>%
  
  group_by(w) %>%
  
  summarise(
    
    Scheduled_Diagnostic = sum(d_hours),
    Scheduled_Therapeutic = sum(t_hours),
    Total_Scheduled_Hours = sum(total_hours),
    
    Diagnostic_Rooms = sum(room_type == "Diagnostic"),
    Therapeutic_Rooms = sum(room_type == "Therapeutic"),
    Unused_Rooms = sum(room_type == "Unused"),
    
    .groups = "drop"
  ) %>%
  
  mutate(
    
    Demand_Diagnostic = P_diag[w],
    Demand_Therapeutic = P_thera[w],
    
    Clinician_Hours = C[w],
     Utilisation = round(
      Total_Scheduled_Hours / Clinician_Hours,  2),
    Demand_Met = ifelse(
      Scheduled_Diagnostic >= Demand_Diagnostic &
        Scheduled_Therapeutic >= Demand_Therapeutic,
      "Yes","No"))

#---------------------------------------------------------
# 11. Weekly Results Table (Report Table)
#---------------------------------------------------------

gt(weekly_summary) %>%
  
  tab_header(
    title = md("**Weekly Endoscopy Scheduling Results**"),
    subtitle = "Demand satisfaction and resource utilisation"
  ) %>%
  
  cols_align(align = "center") %>%
  
  fmt_number(
    columns = c(
      Scheduled_Diagnostic,
      Scheduled_Therapeutic,
      Total_Scheduled_Hours,Utilisation), decimals = 1 )

#---------------------------------------------------------
# 10. Weekly Results Summary (taken from AI )
#---------------------------------------------------------

weekly_summary <- table_data %>%
  group_by(w) %>%
  summarise(
    Scheduled_Diagnostic = sum(d_hours),
    Scheduled_Therapeutic = sum(t_hours),
    Total_Scheduled_Hours = sum(total_hours),
    
    Diagnostic_Rooms = sum(room_type == "Diagnostic"),
    Therapeutic_Rooms = sum(room_type == "Therapeutic"),
    Unused_Rooms = sum(room_type == "Unused"),
    
    .groups = "drop"
  ) %>%
  mutate(
    Demand_Diagnostic = P_diag[w],
    Demand_Therapeutic = P_thera[w],
    Clinician_Hours = C[w],
    Utilisation = round(Total_Scheduled_Hours / Clinician_Hours, 2),
    Demand_Met = ifelse(
      Scheduled_Diagnostic >= Demand_Diagnostic &
        Scheduled_Therapeutic >= Demand_Therapeutic,
      "Yes","No"
    )
  )

#---------------------------------------------------------
# 11. Weekly Results Table 
#---------------------------------------------------------

weekly_summary %>%
  gt() %>%
  
  tab_header(
    title = md("**Weekly Endoscopy Scheduling Results**"),
    subtitle = md("Demand satisfaction and resource utilisation")
  ) %>%
  
  
  cols_align(align = "center") %>%
  
  fmt_number(
    columns = c(Scheduled_Diagnostic, Scheduled_Therapeutic, Total_Scheduled_Hours, Utilisation),
    decimals = 1
  ) %>%
  
  tab_style(
    style = list(
      cell_fill(color = "lightblue"),     
      cell_text(weight = "bold", color = "black")  
    ),
    locations = cells_column_labels(everything())
  ) %>%
  
  data_color(
    columns = vars(Utilisation),
    colors = scales::col_numeric(
      palette = c("white", "mediumblue"),
      domain = c(0, max(weekly_summary$Utilisation))
    )
  ) %>%
  
 # highlight if demand is not met 
  tab_style(
    style = list(
      cell_fill(color = "#FFCCCC"),  # Light red fill
      cell_text(weight = "bold") ),
    locations = cells_body(
      columns = vars(Demand_Met),
      rows = Demand_Met == "No"
    ))

#---------------------------------------------------------
# 12. Visualization: Room Configuration Over Time
#---------------------------------------------------------

ggplot(table_data, aes(x = w, y = factor(r))) +
  geom_point(
    aes(color = room_type),size = 5) +
  
  geom_point(
    data = subset(table_data, setup > 0.5),
    aes(x = w, y = factor(r)),color = "darkred",size = 4,shape = 8) +
  
  labs(
    title = "Room Configuration Over Time (Red * = Setup)",
    x = "Week",y = "Room", color = "Room Type") +
  
  scale_color_manual(values = c(
    "Diagnostic" = "lightseagreen",
    "Therapeutic" = "deepskyblue",
    "Unused" = "darkgrey")) +
  theme_minimal()

#---------------------------------------------------------
# 13. Visualisation: Demand vs Scheduled
#---------------------------------------------------------

demand_plot_data <- weekly_summary %>%
  
  select( w,Scheduled_Diagnostic,Scheduled_Therapeutic,Demand_Diagnostic,
          Demand_Therapeutic ) %>%
  
  pivot_longer(-w,names_to = "type",values_to = "hours")

ggplot(demand_plot_data, aes(x = w, y = hours, color = type)) +
  geom_line(size = 1) +
   geom_point(
    data = subset(demand_plot_data, grepl("Demand", type)),size = 2) +
  theme_minimal()

#---------------------------------------------------------
# 14. Visualisation: Staff Availability vs Scheduled Hours
#---------------------------------------------------------

ggplot(weekly_summary, aes(x = w)) +
  geom_line(
    aes(y = Total_Scheduled_Hours, color = "Scheduled"),size = 1.2 ) +
  
  geom_line(
    aes(y = Clinician_Hours, color = "Available"), size = 1.2) +
  
  scale_color_manual(values = c(
    "Scheduled" = "lightblue", "Available" = "darkred")) +
  labs(
    color = "Hours") +
  theme_minimal()

#---------------------------------------------------------
# 15. Visualisation: Room Usage by Size ( Adapted with the help of AI )
#---------------------------------------------------------

room_size <- data.frame(
  r = 1:10,
  size = c(rep("Small",3),rep("Medium",4),rep("Large",3))
)

room_usage <- table_data %>%
  
  group_by(r) %>%
  
  summarise(total_hours = sum(total_hours)) %>%
  
  left_join(room_size, by = "r") %>%
  
  group_by(size) %>%
  
  summarise(total_hours = sum(total_hours), .groups = "drop")

ggplot(room_usage,
       aes(x = size,y = total_hours,fill = size)) +
  geom_col() +
  labs(
    title = "Total Usage by Room Size",
    x = "Room Size",y = "Total Scheduled Hours") +
  theme_minimal()
