# config/routes.rb

Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      resources :video_calls, only: [] do
        collection do
          get :video_call_history
          get :all_call_history
          get :recent_call_history
          delete :remove_recent_call_history
          delete :remove_all_call_history
        end

        member do
          delete :remove_any_call_log
          delete :remove_video_call_log
          post :videocall
          delete :destroy_room
        end
      end
    end
  end
end
